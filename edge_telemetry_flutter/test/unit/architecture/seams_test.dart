// test/unit/architecture/seams_test.dart
//
// The six test seams the 5-layer refactor exists to make possible (ticket #18).
// Each asserts external behaviour at a seam, never a private field.

import 'package:edge_telemetry_flutter/src/capture/capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/nav_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/config/telemetry_config.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/crash/crash_reporting.dart';
import 'package:edge_telemetry_flutter/src/facade/edge_telemetry.dart';
import 'package:edge_telemetry_flutter/src/facade/telemetry_wiring.dart';
import 'package:edge_telemetry_flutter/src/managers/breadcrumb_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every payload that would go on the wire.
class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];
  Future<bool> call(Map<String, dynamic> payload) async {
    sent.add(payload);
    return true;
  }
}

/// Fails every send (network down), so callers exercise the persist path.
class _FailingSender {
  Future<bool> call(Map<String, dynamic> payload) async => false;
}

/// A fake queue that records persists and replays canned payloads on drain —
/// lets us test [RetryTransport] without touching path_provider / disk.
class _FakeQueue extends OfflineQueue {
  final List<Map<String, dynamic>> persisted = [];
  final List<Map<String, dynamic>> pending = [];
  final List<Map<String, dynamic>> drainOrder = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> persist(Map<String, dynamic> payload) async {
    persisted.add(payload);
    pending.add(payload);
    return 'fake_${persisted.length}.json';
  }

  @override
  Future<int> drain(Future<bool> Function(Map<String, dynamic>) send) async {
    var count = 0;
    for (final payload in List.of(pending)) {
      if (await send(payload)) {
        drainOrder.add(payload);
        pending.remove(payload);
        count++;
      }
    }
    return count;
  }
}

/// Collects [EdgeEvent]s emitted by a capture hook.
class _FakeSink implements EventSink {
  final List<EdgeEvent> events = [];
  @override
  void add(EdgeEvent event) => events.add(event);
}

const _config = TelemetryConfig(
  serviceName: 'test',
  endpoint: 'https://example.test/telemetry',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Seam 1 — EdgeTelemetry.fromWiring injects a faked stack', () {
    test('facade.trackEvent delegates through the injected collector→transport',
        () async {
      final sender = _RecordingSender();
      final session = SessionManager();
      await session.startSession('session_test');
      final context = ContextManager(
          sessionManager: session, global: {'device.id': 'device_x'});
      final queue = _FakeQueue();
      final transport = RetryTransport(
          endpoint: _config.endpoint, queue: queue, sender: sender.call);
      final pipeline = Pipeline(transport: transport, batchSize: 1);
      final collector =
          Collector(context: context, session: session, pipeline: pipeline);
      final wiring = TelemetryWiring(
        config: _config,
        session: session,
        context: context,
        breadcrumbs: BreadcrumbManager(),
        crashReporting: const CrashReporting(),
        queue: queue,
        transport: transport,
        pipeline: pipeline,
        collector: collector,
        disposers: const [],
      );

      final telemetry = EdgeTelemetry.fromWiring(wiring);
      telemetry.trackEvent('demo.click', attributes: {'button': 'x'});
      await Future<void>(() {});

      expect(sender.sent, hasLength(1));
      final batch = sender.sent.single;
      expect(batch['type'], 'telemetry_batch');
      final events = batch['events'] as List;
      // Host names wrap into custom_event with event.name carrying the name.
      expect(events.single['eventName'], 'custom_event');
      final attrs = events.single['attributes'] as Map;
      expect(attrs['event.name'], 'demo.click');
      expect(attrs['button'], 'x');
      expect(attrs['device.id'], 'device_x');
    });
  });

  group('Seam 2 — EventSink injected into a CaptureHook', () {
    test('NavCaptureHook emits navigation to a fake sink', () {
      final sink = _FakeSink();
      final hook = NavCaptureHook(
          session: SessionManager(), breadcrumbs: BreadcrumbManager());
      hook.start(sink);

      hook.observer!.didPush(
        MaterialPageRoute<void>(
            builder: (_) => const SizedBox(),
            settings: const RouteSettings(name: '/home')),
        null,
      );

      final nav = sink.events.firstWhere((e) => e.name == 'navigation');
      expect(nav.type, 'event');
      expect(nav.attributes['navigation.to'], '/home');
      expect(nav.countsToSession, isFalse); // nav sent direct in v1.5.2
    });
  });

  group('Seam 3 — ContextManager.snapshot()', () {
    test('folds globals, live session attrs, and network.type', () async {
      final session = SessionManager();
      await session.startSession('session_abc');
      final context = ContextManager(
        sessionManager: session,
        global: {'device.id': 'device_1', 'user.id': 'user_1'},
        networkType: 'wifi',
      );

      final snap = context.snapshot();
      expect(snap['device.id'], 'device_1');
      expect(snap['user.id'], 'user_1');
      expect(snap['session.id'], 'session_abc');
      expect(snap['network.type'], 'wifi');

      context.networkType = 'mobile';
      expect(context.snapshot()['network.type'], 'mobile');
    });
  });

  group('Seam 4 — RetryTransport injected into Pipeline', () {
    test('batched enqueue builds the telemetry batch envelope', () async {
      final sender = _RecordingSender();
      final transport = RetryTransport(
          endpoint: _config.endpoint, queue: _FakeQueue(), sender: sender.call);
      final pipeline = Pipeline(transport: transport, batchSize: 2);

      pipeline.enqueue({'type': 'event', 'eventName': 'a'});
      expect(sender.sent, isEmpty); // buffered, not yet flushed
      pipeline.enqueue({'type': 'event', 'eventName': 'b'});
      await Future<void>(() {});

      expect(sender.sent, hasLength(1));
      final batch = sender.sent.single;
      expect(batch['type'], 'telemetry_batch');
      expect(batch['batch_size'], 2);
      expect((batch['events'] as List).map((e) => e['eventName']), ['a', 'b']);
    });

    test('sendNow bypasses the batch (immediate path)', () async {
      final sender = _RecordingSender();
      final transport = RetryTransport(
          endpoint: _config.endpoint, queue: _FakeQueue(), sender: sender.call);
      final pipeline = Pipeline(transport: transport, batchSize: 99);

      pipeline.sendNow({'type': 'error', 'error': 'boom'});
      await Future<void>(() {});

      expect(sender.sent, hasLength(1));
      expect(sender.sent.single['type'], 'error'); // bare, not wrapped
    });
  });

  group('Seam 5 — Collector sample gate + session.sampled', () {
    test('sampled-out drops batched events but keeps immediate crashes',
        () async {
      final sender = _RecordingSender();
      final session = SessionManager();
      await session.startSession('session_s');
      final context = ContextManager(sessionManager: session);
      context.setGlobalAttribute('session.sampled', 'false');
      final transport = RetryTransport(
          endpoint: _config.endpoint, queue: _FakeQueue(), sender: sender.call);
      final pipeline = Pipeline(transport: transport, batchSize: 1);
      final collector =
          Collector(context: context, session: session, pipeline: pipeline);

      // A canon event (passes the allowlist) so the drop is purely sampling.
      collector.add(const EdgeEvent.event('navigation'));
      await Future<void>(() {});
      expect(sender.sent, isEmpty); // batched event dropped

      collector.add(EdgeEvent.error(StateError('boom')));
      await Future<void>(() {});
      expect(sender.sent, hasLength(1)); // crash still sent
      expect(sender.sent.single['type'], 'event'); // immediate app.crash
      expect(sender.sent.single['eventName'], 'app.crash');
    });
  });

  group('Seam 6 — OfflineQueue injected into RetryTransport', () {
    test('persists on network failure, drains FIFO on reconnect', () async {
      final queue = _FakeQueue();
      final failing = _FailingSender();
      final downTransport = RetryTransport(
          endpoint: _config.endpoint, queue: queue, sender: failing.call);

      await downTransport.sendImmediate({'type': 'error', 'error': 'c1'});
      await downTransport.sendImmediate({'type': 'error', 'error': 'c2'});
      expect(queue.persisted.map((p) => p['error']), ['c1', 'c2']);

      // Reconnect: a successful batch send drains the queue FIFO.
      final recovered = _RecordingSender();
      final upTransport = RetryTransport(
          endpoint: _config.endpoint, queue: queue, sender: recovered.call);
      await upTransport.drainQueue();

      expect(queue.drainOrder.map((p) => p['error']), ['c1', 'c2']);
      expect(queue.pending, isEmpty);
    });
  });
}
