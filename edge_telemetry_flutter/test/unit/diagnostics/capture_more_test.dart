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

class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];
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
  Future<int> drain(Future<bool> Function(Map<String, dynamic>) s) async => 0;
}

Future<(Collector, _RecordingSender)> _wire(
    {BreadcrumbManager? breadcrumbs}) async {
  final sender = _RecordingSender();
  final session = SessionManager();
  await session.startSession('session_test');
  final context =
      ContextManager(sessionManager: session, global: {'device.id': 'd'});
  final transport = RetryTransport(
      endpoint: 'https://x.test', queue: _NoopQueue(), sender: sender.call);
  final pipeline = Pipeline(transport: transport, batchSize: 1);
  final collector = Collector(
      context: context,
      session: session,
      pipeline: pipeline,
      breadcrumbs: breadcrumbs);
  return (collector, sender);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Breadcrumb ring', () {
    test('caps at 20 (oldest dropped)', () {
      final ring = BreadcrumbManager();
      for (var i = 0; i < 25; i++) {
        ring.addCustom('crumb_$i');
      }
      expect(ring.count, 20);
      // Most-recent-first; crumb_5..crumb_24 survive, crumb_0..4 dropped.
      final messages = ring.getBreadcrumbs().map((b) => b.message).toList();
      expect(messages.first, 'crumb_24');
      expect(messages.contains('crumb_4'), isFalse);
    });

    test('attached to app.crash as crash.breadcrumbs, absent on other events',
        () async {
      final ring = BreadcrumbManager()..addNavigation('/home');
      final (collector, sender) = await _wire(breadcrumbs: ring);

      collector.add(EdgeEvent.error(StateError('boom')));
      await Future<void>(() {});

      // app.crash rides the immediate rail: bare event, not a batch envelope.
      final crashAttrs = sender.sent.single['attributes'] as Map;
      expect(crashAttrs.containsKey('crash.breadcrumbs'), isTrue);
      final decoded =
          jsonDecode(crashAttrs['crash.breadcrumbs'] as String) as List;
      expect((decoded.single as Map)['category'], 'navigation');

      // A non-crash event never carries the ring.
      collector.add(const EdgeEvent.event('navigation'));
      await Future<void>(() {});
      final navAttrs =
          (sender.sent[1]['events'] as List).single['attributes'] as Map;
      expect(navAttrs.containsKey('crash.breadcrumbs'), isFalse);
    });

    test('empty ring adds no key', () async {
      final (collector, sender) = await _wire(breadcrumbs: BreadcrumbManager());
      collector.add(EdgeEvent.error(StateError('boom')));
      await Future<void>(() {});
      final attrs = sender.sent.single['attributes'] as Map;
      expect(attrs.containsKey('crash.breadcrumbs'), isFalse);
    });
  });

  group('Device context', () {
    test('platform_brightness always present; accessibility keys gated off',
        () async {
      final session = SessionManager();
      await session.startSession('s');
      final ctx = ContextManager(sessionManager: session);
      final snap = ctx.snapshot();
      expect(snap.containsKey('device.platform_brightness'), isTrue);
      expect(snap.containsKey('device.text_scale_factor'), isFalse);
      expect(snap.containsKey('device.reduce_motion'), isFalse);
    });

    test('accessibility keys present when opted in', () async {
      final session = SessionManager();
      await session.startSession('s');
      final ctx = ContextManager(
          sessionManager: session, captureAccessibilityContext: true);
      final snap = ctx.snapshot();
      expect(snap.containsKey('device.text_scale_factor'), isTrue);
      expect(snap.containsKey('device.reduce_motion'), isTrue);
    });
  });

  group('Navigation route context', () {
    test('route.has_arguments is a boolean on navigation + screen.duration',
        () {
      final events = <(String, Map<String, String>?)>[];
      final observer = EdgeNavigationObserver(
          onEvent: (name, {attributes}) => events.add((name, attributes)));

      final withArgs = MaterialPageRoute<void>(
          builder: (_) => const SizedBox(),
          settings: const RouteSettings(name: '/a', arguments: {'id': 1}));
      final next = MaterialPageRoute<void>(
          builder: (_) => const SizedBox(),
          settings: const RouteSettings(name: '/b'));

      observer.didPush(withArgs, null);
      observer.didPush(next, withArgs); // closes /a → screen.duration

      final nav = events.firstWhere((e) => e.$1 == 'navigation').$2!;
      expect(nav['route.has_arguments'], 'true');
      expect(nav['route.type'], 'MaterialPageRoute<void>');
      // Never the values.
      expect(nav.keys.any((k) => k.contains('arguments_type')), isFalse);

      final dur = events.firstWhere((e) => e.$1 == 'screen.duration').$2!;
      expect(dur['route.type'], 'MaterialPageRoute<void>');
      expect(dur['route.has_arguments'], 'true');
    });
  });
}
