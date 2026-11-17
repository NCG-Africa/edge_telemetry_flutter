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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const reporting = CrashReporting();

  group('buildCrashEvent — shape', () {
    test('error.* keys, an unhandled Dart error is a batched app.crash', () {
      final event = reporting.buildCrashEvent(
        StateError('boom'),
        stackTrace: StackTrace.fromString('#0 main'),
        source: 'flutter_error',
      );

      expect(event.type, 'event');
      expect(event.name, 'app.crash');
      // The rail moved in #90: a non-fatal's process lives, so it batches and
      // gets the Pipeline's retries instead of one attempt.
      expect(event.priority, EventPriority.batched);
      expect(event.bypassSampling, isTrue); // rail and sampling are orthogonal
      expect(event.countsToSession, isFalse);

      final a = event.attributes;
      expect(a['error.message'], 'Bad state: boom');
      expect(a['error.type'], 'StateError');
      expect(a['error.stacktrace'], '#0 main');
      expect(a['error.cause'], 'unhandled_exception');
      expect(a.containsKey('is_fatal'), isFalse);
      expect(a.containsKey('handled'), isFalse);
      expect(a['error.source'], 'flutter_error');
    });

    test('records each handler in error.source', () {
      for (final source in [
        'flutter_error',
        'platform_dispatcher',
        'zone',
        'isolate',
      ]) {
        final e = reporting.buildCrashEvent(Exception('x'), source: source);
        expect(e.attributes['error.source'], source);
        // `zone` is not an auto handler: a live catch, so app.error.
        expect(e.name, source == 'zone' ? 'app.error' : 'app.crash');
      }
    });

    test('no client-derived crash_hash / severity / breadcrumbs', () {
      final a = reporting.buildCrashEvent(Exception('x')).attributes;
      expect(a.containsKey('crash_hash'), isFalse);
      expect(a.containsKey('crash.fingerprint'), isFalse);
      expect(a.containsKey('severity'), isFalse);
      expect(a.containsKey('breadcrumbs'), isFalse);
    });

    test('host trackError (no source) is app.error without error.source', () {
      final event = reporting.buildCrashEvent(
        Exception('x'),
        attributes: {'error.context': 'demo'},
      );
      final a = event.attributes;
      expect(event.name, 'app.error');
      expect(a['error.cause'], 'handled');
      expect(a.containsKey('error.source'), isFalse);
      expect(a['error.context'], 'demo');
    });

    test('null stackTrace omits the stacktrace key', () {
      final a = reporting.buildCrashEvent(Exception('x')).attributes;
      expect(a.containsKey('error.stacktrace'), isFalse);
    });
  });

  group('buildNativeCrashEvent — native taxonomy carried verbatim', () {
    test('plugin keys become the catalogue keys; cause picks the event', () {
      final event = reporting.buildNativeCrashEvent({
        'message': 'SIGSEGV',
        'stacktrace': 'frame0\nframe1',
        'exception_type': 'EXC_BAD_ACCESS',
        'cause': 'NativeCrash',
        'is_fatal': 'true',
        'crash.source': 'metrickit',
        'native_capture_tier': 'full',
      });

      expect(event.name, 'app.crash');
      expect(event.priority, EventPriority.immediate);
      expect(event.bypassSampling, isTrue);

      final a = event.attributes;
      expect(a['error.cause'], 'native_crash');
      expect(a['error.message'], 'SIGSEGV');
      expect(a['error.type'], 'EXC_BAD_ACCESS');
      expect(a['error.stacktrace'], 'frame0\nframe1');
      expect(a.containsKey('is_fatal'), isFalse);
      expect(a['error.source'], 'metrickit');
      expect(a['native_capture_tier'], 'full');
    });

    test('ANR is app.anr; a pre-4.0 stored sdk.-prefixed tier is renamed '
        '(R1)', () {
      final event = reporting.buildNativeCrashEvent({
        'message': 'ANR in com.example',
        'cause': 'ANR',
        'is_fatal': 'true',
        'crash.source': 'app_exit_info',
        'sdk.native_capture_tier': 'jvm_only',
      });
      final a = event.attributes;
      expect(event.name, 'app.anr');
      expect(a['error.cause'], 'anr');
      expect(a['native_capture_tier'], 'jvm_only');
      expect(a.containsKey('sdk.native_capture_tier'), isFalse);
    });
  });

  group('rail routing', () {
    Future<(Collector, _RecordingSender, Pipeline)> wire() async {
      final sender = _RecordingSender();
      final session = SessionManager();
      await session.startSession('session_test');
      final context = ContextManager(
        sessionManager: session,
        global: {'device.model': 'device_x'},
      );
      final transport = RetryTransport(
        endpoint: 'https://api.test',
        queue: _NoopQueue(),
        sender: sender.call,
      );
      // batchSize huge → a batched event would NOT flush; only the immediate
      // rail can produce a send here.
      final pipeline = Pipeline(
        identity: kTestIdentity,
        transport: transport,
        batchSize: 999,
      );
      final collector = Collector(
        context: context,
        session: session,
        pipeline: pipeline,
      );
      return (collector, sender, pipeline);
    }

    test('a non-fatal buffers on the batch rail, then flushes', () async {
      final (collector, sender, pipeline) = await wire();

      collector.add(
        reporting.buildCrashEvent(
          StateError('boom'),
          source: 'platform_dispatcher',
        ),
      );
      await Future<void>(() {});

      // Nothing yet: batchSize is 999 and the non-fatal is no longer immediate.
      expect(sender.items, isEmpty);

      pipeline.flush();
      await Future<void>(() {});

      expect(sender.items, hasLength(1));
      final wireEvent = sender.items.single;
      expect(wireEvent['type'], 'event');
      expect(wireEvent['eventName'], 'app.crash');
      final attrs = wireEvent['attributes'] as Map;
      expect(attrs['error.cause'], 'unhandled_exception');
      expect(attrs['error.source'], 'platform_dispatcher');
      expect(attrs['device.model'], 'device_x'); // context folded in
    });

    test(
      'native crash reaches the wire as app.crash with tier asserted',
      () async {
        final (collector, sender, _) = await wire();

        collector.add(
          reporting.buildNativeCrashEvent({
            'message': 'SIGSEGV',
            'cause': 'NativeCrash',
            'is_fatal': 'true',
            'crash.source': 'metrickit',
            'native_capture_tier': 'full',
          }),
        );
        await Future<void>(() {});

        expect(sender.items, hasLength(1));
        final attrs = sender.items.single['attributes'] as Map;
        expect(sender.items.single['eventName'], 'app.crash');
        expect(attrs['error.cause'], 'native_crash');
        expect(attrs['native_capture_tier'], 'full'); // tiering asserted
        expect(attrs.containsKey('device.id'), isFalse); // envelope only (R1)
      },
    );
  });
}
