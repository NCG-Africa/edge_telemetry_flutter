// test/unit/capture/screen_load_test.dart
//
// Wayfinder #88 — per-screen load timing at the wire seam. Asserts the four
// outcomes, both source values, the deleted cardinality bomb, and the dwell
// that folds onto `navigation` instead of emitting a second item.

import 'package:edge_telemetry_flutter/src/capture/capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/nav_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/screen_load_hook.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/screen_inflight.dart';
import 'package:edge_telemetry_flutter/src/managers/breadcrumb_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/trace_manager.dart';
import 'package:edge_telemetry_flutter/src/widgets/edge_navigation_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSink implements EventSink {
  final List<EdgeEvent> events = [];

  @override
  void add(EdgeEvent event) => events.add(event);

  List<EdgeEvent> named(String name) =>
      events.where((e) => e.name == name).toList();
}

MaterialPageRoute<void> _route(String? name) => MaterialPageRoute<void>(
      builder: (_) => const SizedBox(),
      settings: RouteSettings(name: name),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SessionManager session;
  late _FakeSink sink;
  late ScreenLoadHook hook;
  late EdgeNavigationObserver observer;
  late DisposeHandle disposeHook;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    resetScreenInflight();
    session = SessionManager();
    await session.startSession('s1');
    sink = _FakeSink();
    hook = ScreenLoadHook(session: session);
    disposeHook = hook.start(sink);
    final nav = NavCaptureHook(
      session: session,
      breadcrumbs: BreadcrumbManager(),
      screenLoad: hook,
    );
    nav.start(sink);
    observer = nav.observer!;
  });

  tearDown(() {
    // Cancels the open load's 10 s deadline timer — a screen entry with no
    // terminal is the normal end state of most of these tests.
    disposeHook();
    resetScreenInflight();
  });

  /// Let whatever screen is still open reach its `settled` terminal, so no
  /// deadline timer outlives the test body.
  Future<void> settleOpen(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(kScreenQuietWindow);
  }

  Map<String, String> onlyLoad() {
    final loads = sink.named('screen.load');
    expect(loads, hasLength(1));
    return loads.single.attributes;
  }

  group('#88 — the four outcomes', () {
    testWidgets('settled: first frame + no in-flight + a quiet window',
        (tester) async {
      observer.didPush(_route('/a'), null);
      await tester.pump(); // first frame
      expect(sink.named('screen.load'), isEmpty, reason: 'quiet not held yet');

      await tester.pump(kScreenQuietWindow);

      final a = onlyLoad();
      expect(a['screen.load.outcome'], kScreenLoadSettled);
      expect(a['screen.load.source'], kScreenLoadInferred);
      expect(a['screen.name'], '/a');
      expect(a['screen.load.first_frame_ms'], isNotNull);
      expect(a['screen.load.settled_ms'], isNotNull);
    });

    testWidgets('abandoned: the user navigates away first', (tester) async {
      observer.didPush(_route('/a'), null);
      await tester.pump();
      observer.didPush(_route('/b'), _route('/a'));

      final a = onlyLoad();
      expect(a['screen.name'], '/a');
      expect(a['screen.load.outcome'], kScreenLoadAbandoned);
      // Non-settled paths carry no duration of their own.
      expect(a.containsKey('screen.load.settled_ms'), isFalse);

      await settleOpen(tester);
    });

    testWidgets('deadline_exceeded, pinned to the action-root cap',
        (tester) async {
      expect(ScreenLoadHook.deadline, TraceManager.rootCap);

      observer.didPush(_route('/a'), null);
      await tester.pump();
      // Hold one request open past the deadline so the quiet window never arms.
      final claim = beginScreenRequest();
      expect(claim, session.currentScreenId);

      await tester.pump(ScreenLoadHook.deadline);

      final a = onlyLoad();
      expect(a['screen.load.outcome'], kScreenLoadDeadlineExceeded);
      expect(a.containsKey('screen.load.settled_ms'), isFalse);
      // The first frame is still a fact, and still reported.
      expect(a['screen.load.first_frame_ms'], isNotNull);

      endScreenRequest(claim);
    });

    testWidgets('backgrounded: paused before the screen settles',
        (tester) async {
      observer.didPush(_route('/a'), null);
      hook.onPaused();

      final a = onlyLoad();
      expect(a['screen.load.outcome'], kScreenLoadBackgrounded);
      expect(a.containsKey('screen.load.settled_ms'), isFalse);
      // Never painted, so no first-frame number either — absent, not zero.
      expect(a.containsKey('screen.load.first_frame_ms'), isFalse);
    });
  });

  group('#88 — the source key', () {
    testWidgets('an explicit report overrides the inference', (tester) async {
      observer.didPush(_route('/a'), null);
      await tester.pump();
      hook.reportSettled();

      final a = onlyLoad();
      expect(a['screen.load.outcome'], kScreenLoadSettled);
      expect(a['screen.load.source'], kScreenLoadReported);

      // The inference's quiet window finds no open load — one event per entry.
      await tester.pump(kScreenQuietWindow * 2);
      expect(sink.named('screen.load'), hasLength(1));
    });

    testWidgets('an in-flight request on this screen defers settling',
        (tester) async {
      observer.didPush(_route('/a'), null);
      await tester.pump();

      final claim = beginScreenRequest();
      await tester.pump(kScreenQuietWindow * 2);
      expect(sink.named('screen.load'), isEmpty);

      endScreenRequest(claim);
      await tester.pump(kScreenQuietWindow);
      expect(onlyLoad()['screen.load.outcome'], kScreenLoadSettled);
    });
  });

  group('#88 — the cardinality bomb is gone', () {
    testWidgets('three visits: one stable name, three screen ids',
        (tester) async {
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        observer.didPush(_route(null), i == 0 ? null : _route(null));
        await tester.pump();
        ids.add(session.currentScreenId!);
        await tester.pump(kScreenQuietWindow);
      }

      final names = sink
          .named('screen.load')
          .map((e) => e.attributes['screen.name'])
          .toSet();
      expect(names, hasLength(1), reason: 'one grouping key for one route');
      expect(names.single, 'unnamed_MaterialPageRoute<void>');
      expect(names.single, isNot(contains(RegExp(r'\d{4,}'))),
          reason: 'no identity hash');
      expect(ids.toSet(), hasLength(3), reason: 'visit identity is screen.id');
    });
  });

  group('#88 — dwell folds onto navigation', () {
    testWidgets('no screen.duration event; the navigation carries it',
        (tester) async {
      observer.didPush(_route('/a'), null);
      await tester.pump();
      observer.didPush(_route('/b'), _route('/a'));

      expect(sink.named('screen.duration'), isEmpty);
      final navs = sink.named('navigation');
      expect(navs, hasLength(2));
      final second = navs.last.attributes;
      expect(second['navigation.from'], '/a');
      expect(second['screen.previous_duration_ms'], isNotNull);
      expect(second['screen.previous_exit_method'], 'push');

      await settleOpen(tester);
    });

    testWidgets('a screen that never painted reports no dwell', (tester) async {
      // Pushed and superseded inside the same frame — never visible.
      observer.didPush(_route('/a'), null);
      observer.didPush(_route('/b'), _route('/a'));

      final second = sink.named('navigation').last.attributes;
      expect(second.containsKey('screen.previous_duration_ms'), isFalse);

      await settleOpen(tester);
    });
  });
}
