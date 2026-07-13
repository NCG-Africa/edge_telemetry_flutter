// test/unit/crash/crash_reporting_test.dart
//
// Crash unification (#22): every Dart handler funnels into one immediate
// `app.crash` event with unprefixed keys, `cause=Error`, `is_fatal=false`, and
// the catching handler recorded in the secondary `crash.source`. Tests the
// CrashReporting seam (cause + source + unprefixed payload) and end-to-end
// immediate routing through Collector → Pipeline → transport.

import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/crash/crash_reporting.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
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
  Future<String?> persist(Map<String, dynamic> p) async => null;
  @override
  Future<int> drain(Future<bool> Function(Map<String, dynamic>) s) async => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const reporting = CrashReporting();

  group('buildCrashEvent — shape', () {
    test('unprefixed keys, cause=Error, is_fatal=false, immediate app.crash',
        () {
      final event = reporting.buildCrashEvent(
        StateError('boom'),
        stackTrace: StackTrace.fromString('#0 main'),
        source: 'flutter_error',
      );

      expect(event.type, 'event');
      expect(event.name, 'app.crash');
      expect(event.priority, EventPriority.immediate);
      expect(event.countsToSession, isFalse);

      final a = event.attributes;
      expect(a['message'], 'Bad state: boom');
      expect(a['exception_type'], 'StateError');
      expect(a['stacktrace'], '#0 main');
      expect(a['cause'], 'Error');
      expect(a['is_fatal'], 'false');
      expect(a['crash.source'], 'flutter_error');
    });

    test('records each handler in crash.source', () {
      for (final source in [
        'flutter_error',
        'platform_dispatcher',
        'zone',
        'isolate',
      ]) {
        final e = reporting.buildCrashEvent(Exception('x'), source: source);
        expect(e.attributes['crash.source'], source);
        expect(e.attributes['cause'], 'Error'); // source never leaks into cause
      }
    });

    test('no client-derived crash_hash / severity / breadcrumbs', () {
      final a = reporting.buildCrashEvent(Exception('x')).attributes;
      expect(a.containsKey('crash_hash'), isFalse);
      expect(a.containsKey('crash.fingerprint'), isFalse);
      expect(a.containsKey('severity'), isFalse);
      expect(a.containsKey('breadcrumbs'), isFalse);
    });

    test('host trackError (no source) omits crash.source; caller attrs merge',
        () {
      final a = reporting.buildCrashEvent(
        Exception('x'),
        attributes: {'error.context': 'demo'},
      ).attributes;
      expect(a.containsKey('crash.source'), isFalse);
      expect(a['error.context'], 'demo');
    });

    test('null stackTrace omits the stacktrace key', () {
      final a = reporting.buildCrashEvent(Exception('x')).attributes;
      expect(a.containsKey('stacktrace'), isFalse);
    });
  });

  group('immediate routing', () {
    Future<(Collector, _RecordingSender)> wire() async {
      final sender = _RecordingSender();
      final session = SessionManager();
      await session.startSession('session_test');
      final context = ContextManager(
          sessionManager: session, global: {'device.id': 'device_x'});
      final transport = RetryTransport(
          endpoint: 'https://api.test',
          queue: _NoopQueue(),
          sender: sender.call);
      // batchSize huge → a batched event would NOT flush; only the immediate
      // rail can produce a send here.
      final pipeline = Pipeline(transport: transport, batchSize: 999);
      final collector =
          Collector(context: context, session: session, pipeline: pipeline);
      return (collector, sender);
    }

    test('crash bypasses the batch and sends immediately', () async {
      final (collector, sender) = await wire();

      collector.add(reporting.buildCrashEvent(StateError('boom'),
          source: 'platform_dispatcher'));
      await Future<void>(() {});

      expect(sender.sent, hasLength(1));
      final wireEvent = sender.sent.single;
      expect(wireEvent['type'], 'event');
      expect(wireEvent['eventName'], 'app.crash');
      final attrs = wireEvent['attributes'] as Map;
      expect(attrs['cause'], 'Error');
      expect(attrs['is_fatal'], 'false');
      expect(attrs['crash.source'], 'platform_dispatcher');
      expect(attrs['device.id'], 'device_x'); // identity context folded in
    });
  });
}
