// test/unit/capture/action_capture_test.dart
//
// User actions from the pointer route (#84). The seams worth guarding are the
// three that fail silently: a scroll coming to a stop must mint nothing (a
// root minted there would silently reparent the next request onto a scroll),
// the naming call must produce exactly one event rather than a second one, and
// the emission cap must shed events while `session.action_count` keeps
// reporting every root minted.

import 'package:edge_telemetry_flutter/src/capture/action_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/nav_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/core/capture_gate.dart';
import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/config/collection_tier.dart';
import 'package:edge_telemetry_flutter/src/core/config/telemetry_config.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/managers/breadcrumb_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/trace_manager.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = TelemetryConfig(
    serviceName: 'test', endpoint: 'https://example.test', apiKey: 'k');

class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];

  List<Map<String, dynamic>> get items => [
        for (final p in sent)
          ...?(p['events'] as List?)?.cast<Map<String, dynamic>>()
      ];

  List<Map<String, String>> attributesOf(String eventName) => [
        for (final i in items)
          if (i['eventName'] == eventName)
            (i['attributes'] as Map).cast<String, String>()
      ];

  Future<bool> call(Map<String, dynamic> payload) async {
    sent.add(payload);
    return true;
  }
}

class _NoopQueue extends OfflineQueue {
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> persist(Map<String, dynamic> p,
          {bool isCrash = false}) async =>
      null;
  @override
  Future<int> drain(
          Future<DrainResult> Function(Map<String, dynamic>) s) async =>
      0;
}

/// The assembled stack in the facade's construction order, with the pointer
/// hook started against the real global route.
class _Rig {
  _Rig({TelemetryConfig config = _config, DateTime Function()? clock}) {
    session = SessionManager(
      clock: clock,
      newSessionId: () => 'session_rotated_${++_rotations}',
    );
    trace = TraceManager(session: session, clock: clock);
    context = ContextManager(
        sessionManager: session,
        trace: trace,
        global: {'device.id': 'device_1'});
    pipeline = Pipeline(
      transport: RetryTransport(
          endpoint: config.endpoint, queue: _NoopQueue(), sender: sender.call),
      batchSize: 10000,
    );
    gate =
        CaptureGate(config, onShed: () => session.recordDropped('tier_shed'));
    collector = Collector(
        context: context, session: session, pipeline: pipeline, gate: gate);
    session.onSessionStart = () {
      gate.resetBudget();
      collector.resetActionCap();
    };
    session.bindSink(collector);
    _dispose = ActionCaptureHook(
      trace: trace,
      session: session,
      breadcrumbs: breadcrumbs,
      gate: gate,
    ).start(collector);
  }

  int _rotations = 0;
  final sender = _RecordingSender();
  final breadcrumbs = BreadcrumbManager();
  late final SessionManager session;
  late final TraceManager trace;
  late final ContextManager context;
  late final Pipeline pipeline;
  late final CaptureGate gate;
  late final Collector collector;
  late final DisposeHandle _dispose;

  void flush() => pipeline.flush();
  void dispose() {
    _dispose();
    pipeline.dispose();
  }

  List<Map<String, String>> get interactions =>
      sender.attributesOf('ui.interaction');
}

Route<void> _route(String name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    );

int _pointerId = 0;

/// Drive one completed gesture through the real global pointer route:
/// down, [moves] intermediate samples travelling [travel], then up after
/// [held].
void _gesture(
    {Offset travel = Offset.zero,
    Duration held = const Duration(milliseconds: 80),
    int moves = 0,
    Duration at = Duration.zero}) {
  final router = GestureBinding.instance.pointerRouter;
  final pointer = ++_pointerId;
  const origin = Offset(100, 200);
  router.route(PointerDownEvent(
      pointer: pointer,
      position: origin,
      timeStamp: at,
      kind: PointerDeviceKind.touch));
  for (var i = 1; i <= moves; i++) {
    router.route(PointerMoveEvent(
      pointer: pointer,
      position: origin + travel * (i / moves),
      timeStamp: at + held * (i / moves),
      kind: PointerDeviceKind.touch,
    ));
  }
  router.route(PointerUpEvent(
      pointer: pointer,
      position: origin + travel,
      timeStamp: at + held,
      kind: PointerDeviceKind.touch));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('gesture classification', () {
    testWidgets('a tap mints an interaction root and emits exactly one event',
        (tester) async {
      final rig = _Rig();
      await rig.session.startSession('session_1');
      rig.session.recordScreen('/home');

      _gesture();
      await tester.pump();
      rig.flush();

      expect(rig.interactions, hasLength(1));
      final attrs = rig.interactions.single;
      expect(attrs['ui.type'], 'tap');
      expect(attrs['ui.screen'], '/home');
      expect(attrs['ui.name_source'], 'none');
      expect(attrs.containsKey('ui.target'), isFalse);
      expect(attrs['trace.root_type'], 'interaction');
      // `ui.interaction` describes the root, so its span id *is* the action id.
      expect(attrs['span.id'], attrs['rum.action.id']);
      // Coordinates ship only in the semantics tier, which is not built yet.
      expect(attrs.containsKey('ui.x'), isFalse);
      expect(attrs.containsKey('ui.y'), isFalse);
      rig.dispose();
    });

    testWidgets('a held press under the slop is a long_press', (tester) async {
      final rig = _Rig();
      await rig.session.startSession('session_1');

      _gesture(held: const Duration(milliseconds: 600));
      await tester.pump();
      rig.flush();

      expect(rig.interactions.single['ui.type'], 'long_press');
      rig.dispose();
    });

    testWidgets('a scroll coming to a stop mints nothing and emits nothing',
        (tester) async {
      final rig = _Rig();
      await rig.session.startSession('session_1');

      // 30 px over 2 s = 15 px/s, under kMinFlingVelocity (50). Past the slop,
      // so it is not a tap either — the case a naive classifier calls a swipe.
      _gesture(
          travel: const Offset(0, -30),
          held: const Duration(seconds: 2),
          moves: 8);
      await tester.pump();
      rig.flush();

      expect(rig.interactions, isEmpty);
      expect(rig.trace.current(), isEmpty,
          reason: 'a scroll stop must not supersede the open root');
      rig.collector.add(const EdgeEvent.event('custom_event'));
      rig.flush();
      expect(
          rig.sender
              .attributesOf('custom_event')
              .single['session.action_count'],
          '0');
      rig.dispose();
    });

    testWidgets('a fling mints a root but sheds its event on the default tier',
        (tester) async {
      // Swipes are diagnostic: off by default, and the shed is of the *event*
      // — the root still opens, so the next request keeps its attribution.
      final rig = _Rig();
      await rig.session.startSession('session_1');

      _gesture(
          travel: const Offset(-200, 0),
          held: const Duration(milliseconds: 100),
          moves: 5);
      await tester.pump();
      rig.flush();

      expect(rig.interactions, isEmpty);
      expect(rig.trace.current()['trace.root_type'], 'interaction');
      rig.dispose();
    });

    testWidgets('a fling emits with its direction once swipes are enabled',
        (tester) async {
      final rig = _Rig(
          config: _config.copyWith(captureOverrides: {Capture.swipes: true}));
      await rig.session.startSession('session_1');

      _gesture(
          travel: const Offset(-200, 0),
          held: const Duration(milliseconds: 100),
          moves: 5);
      await tester.pump();
      rig.flush();

      final attrs = rig.interactions.single;
      expect(attrs['ui.type'], 'swipe');
      expect(attrs['ui.direction'], 'left');
      rig.dispose();
    });
  });

  group('the naming call', () {
    testWidgets('names the open root and emits nothing of its own',
        (tester) async {
      final rig = _Rig();
      await rig.session.startSession('session_1');

      // The framework routes the pointer event before it sweeps the arena, so
      // a synchronous `trackAction` from the tapped handler lands here.
      _gesture();
      rig.trace.nameCurrent('transfer');
      await tester.pump();
      rig.flush();

      expect(rig.interactions, hasLength(1),
          reason: 'the naming call must not emit a second event');
      expect(rig.interactions.single['ui.target'], 'transfer');
      expect(rig.interactions.single['ui.name_source'], 'track_action');
      rig.dispose();
    });

    testWidgets('mints a root when none is live, so it never silently no-ops',
        (tester) async {
      final rig = _Rig();
      await rig.session.startSession('session_1');

      rig.trace.nameCurrent('nightly_sync');

      expect(rig.trace.current()['trace.root_type'], 'interaction');
      expect(rig.trace.rootName, 'nightly_sync');
      expect(rig.interactions, isEmpty);
      rig.dispose();
    });
  });

  group('the per-session emission cap', () {
    testWidgets('sheds events past 200 while the action count stays honest',
        (tester) async {
      var clock = DateTime(2026, 1, 1, 9);
      final rig = _Rig(clock: () => clock);
      await rig.session.startSession('session_1');

      for (var i = 0; i < kActionEventCap + 5; i++) {
        _gesture(at: Duration(milliseconds: i * 10));
        // Each tap supersedes the last; the root never has to survive.
        await tester.pump();
      }
      rig.flush();

      expect(rig.interactions, hasLength(kActionEventCap));
      // The count rides every item, so any item emitted after the cap reports
      // it: 205 actions against 200 recorded, not a quiet 200.
      rig.collector.add(const EdgeEvent.event('custom_event'));
      rig.flush();
      expect(
          rig.sender.attributesOf('custom_event').last['session.action_count'],
          '${kActionEventCap + 5}',
          reason: 'the count is of roots minted, not events emitted');

      // Rotate so the finalize bookend ships the drop count. The gesture that
      // triggers the rotation minted its root against the dying session, so
      // the fresh session's first counted action is the next one.
      clock = clock.add(const Duration(minutes: 31));
      _gesture();
      await tester.pump();
      _gesture();
      await tester.pump();
      rig.flush();

      final finalized = rig.sender.attributesOf('session.finalized').single;
      expect(finalized['session.dropped_reasons'], 'action_cap=5');
      // A fresh session starts a fresh allowance, and a fresh count.
      expect(rig.interactions.last['session.action_count'], '1');
      rig.dispose();
    });
  });

  group('the navigation root', () {
    testWidgets('is minted only when no root is live', (tester) async {
      final rig = _Rig();
      await rig.session.startSession('session_1');
      final hook = NavCaptureHook(
          session: rig.session, breadcrumbs: rig.breadcrumbs, trace: rig.trace);
      hook.start(rig.collector);

      // A deep link with nothing open: the navigation re-roots it.
      hook.observer!.didPush(_route('/deep'), null);
      expect(rig.trace.current()['trace.root_type'], 'navigation');

      // A tap that pushes a route keeps its own root.
      _gesture();
      final tapRoot = rig.trace.current();
      hook.observer!.didPush(_route('/next'), _route('/deep'));
      expect(rig.trace.current()['trace.id'], tapRoot['trace.id']);
      expect(rig.trace.current()['trace.root_type'], 'interaction');
      await tester.pump();
      rig.dispose();
    });
  });
}
