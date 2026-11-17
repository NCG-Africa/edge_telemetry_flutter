// test/unit/diagnostics/capture_more_test.dart
//
// Wayfinder #26 — the crash-scoped breadcrumb ring + the Flutter-unique
// "capture more" diagnostics. Asserts behaviour at the seams, not private state.

import 'dart:convert';

import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/managers/breadcrumb_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/widgets/edge_navigation_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../helpers/test_identity.dart';

class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];

  /// Wire items, unwrapped from their `telemetry_batch` envelope. Since #81
  /// both rails envelope — the immediate crash as a one-item batch.
  List<Map<String, dynamic>> get items => [
    for (final p in sent)
      ...?(p['events'] as List?)?.cast<Map<String, dynamic>>(),
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
  Future<String?> persist(
    Map<String, dynamic> p, {
    bool isCrash = false,
  }) async => null;
  @override
  Future<int> drain(
    Future<DrainResult> Function(Map<String, dynamic>) s,
  ) async => 0;
}

Future<(Collector, _RecordingSender)> _wire({
  BreadcrumbManager? breadcrumbs,
}) async {
  final sender = _RecordingSender();
  final session = SessionManager();
  await session.startSession('session_test');
  final context = ContextManager(
    sessionManager: session,
    global: {'device.id': 'd'},
  );
  final transport = RetryTransport(
    endpoint: 'https://x.test',
    queue: _NoopQueue(),
    sender: sender.call,
  );
  final pipeline = Pipeline(
    identity: kTestIdentity,
    transport: transport,
    batchSize: 1,
  );
  final collector = Collector(
    context: context,
    session: session,
    pipeline: pipeline,
    breadcrumbs: breadcrumbs,
  );
  return (collector, sender);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Breadcrumb ring', () {
    test('caps at 50 (oldest dropped)', () {
      final ring = BreadcrumbManager();
      for (var i = 0; i < 55; i++) {
        ring.addCustom('crumb_$i');
      }
      expect(ring.count, 50);
      // Most-recent-first; crumb_5..crumb_54 survive, crumb_0..4 dropped.
      final messages = ring.getBreadcrumbs().map((b) => b.message).toList();
      expect(messages.first, 'crumb_54');
      expect(messages.contains('crumb_4'), isFalse);
    });

    test(
      'attached to app.crash as crash.breadcrumbs, absent on other events',
      () async {
        final ring = BreadcrumbManager()..addNavigation('/home');
        final (collector, sender) = await _wire(breadcrumbs: ring);

        collector.add(EdgeEvent.error(StateError('boom')));
        await Future<void>(() {});

        // A non-fatal batches since #90, and `_wire` uses batchSize 1, so the
        // one item flushes on its own.
        final crashAttrs = sender.items.single['attributes'] as Map;
        expect(crashAttrs.containsKey('error.breadcrumbs'), isTrue);
        final decoded =
            jsonDecode(crashAttrs['error.breadcrumbs'] as String) as List;
        expect((decoded.single as Map)['category'], 'navigation');

        // A non-crash event never carries the ring.
        collector.add(const EdgeEvent.event('navigation'));
        await Future<void>(() {});
        final navAttrs =
            (sender.sent[1]['events'] as List).single['attributes'] as Map;
        expect(navAttrs.containsKey('error.breadcrumbs'), isFalse);
      },
    );

    test('empty ring adds no key', () async {
      final (collector, sender) = await _wire(breadcrumbs: BreadcrumbManager());
      collector.add(EdgeEvent.error(StateError('boom')));
      await Future<void>(() {});
      final attrs = sender.items.single['attributes'] as Map;
      expect(attrs.containsKey('error.breadcrumbs'), isFalse);
    });
  });

  group('Device context', () {
    test(
      'platform_brightness always present; accessibility keys gated off',
      () async {
        final session = SessionManager();
        await session.startSession('s');
        final ctx = ContextManager(sessionManager: session);
        final snap = ctx.snapshot();
        expect(snap.containsKey('device.platform_brightness'), isTrue);
        expect(snap.containsKey('device.text_scale_factor'), isFalse);
        expect(snap.containsKey('device.reduce_motion'), isFalse);
      },
    );

    test('accessibility keys present when opted in', () async {
      final session = SessionManager();
      await session.startSession('s');
      final ctx = ContextManager(
        sessionManager: session,
        captureAccessibilityContext: true,
      );
      final snap = ctx.snapshot();
      expect(snap.containsKey('device.text_scale_factor'), isTrue);
      expect(snap.containsKey('device.reduce_motion'), isTrue);
    });
  });

  group('Navigation route context', () {
    testWidgets('navigation.has_arguments is a boolean, and the dwell is its '
        'own screen.duration', (tester) async {
      final events = <(String, Map<String, String>?)>[];
      final observer = EdgeNavigationObserver(
        onEvent: (name, {attributes}) => events.add((name, attributes)),
      );

      final withArgs = MaterialPageRoute<void>(
        builder: (_) => const SizedBox(),
        settings: const RouteSettings(name: '/a', arguments: {'id': 1}),
      );
      final next = MaterialPageRoute<void>(
        builder: (_) => const SizedBox(),
        settings: const RouteSettings(name: '/b'),
      );

      observer.didPush(withArgs, null);
      await tester.pump(); // /a is now on screen
      observer.didPush(next, withArgs); // closes /a

      final nav = events.first.$2!;
      expect(nav['navigation.method'], 'initial'); // the first screen
      expect(nav['navigation.has_arguments'], 'true');
      expect(nav['navigation.route_type'], 'MaterialPageRoute<void>');
      // Never the values.
      expect(nav.keys.any((k) => k.contains('arguments_type')), isFalse);

      // The visit to /a, then the navigation away from it.
      expect(events.map((e) => e.$1), [
        'navigation',
        'screen.duration',
        'navigation',
      ]);
      final visit = events[1].$2!;
      expect(visit['screen.name'], '/a');
      expect(visit['screen.duration_ms'], isNotNull);
      expect(visit['screen.exit_method'], 'push');
      expect(visit['span.start_time'], endsWith('Z'));
      final second = events.last.$2!;
      expect(second['navigation.from_screen'], '/a');
      expect(second['navigation.method'], 'push');
      expect(second.keys.where((k) => k.startsWith('screen.')), isEmpty);
    });

    testWidgets('a path-shaped route name is a template', (tester) async {
      final events = <Map<String, String>?>[];
      final observer = EdgeNavigationObserver(
        onEvent: (name, {attributes}) => events.add(attributes),
      );
      observer.didPush(
        MaterialPageRoute<void>(
          builder: (_) => const SizedBox(),
          settings: const RouteSettings(name: '/orders/42'),
        ),
        null,
      );
      expect(events.single!['navigation.to_screen'], '/orders/{id}');
    });
  });
}
