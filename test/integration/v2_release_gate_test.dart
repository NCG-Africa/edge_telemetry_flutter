// test/integration/v2_release_gate_test.dart
//
// Phase 5 system-level gate (#30). The per-phase seam tests assert each layer in
// isolation; this drives the *assembled* stack through the real facade and
// asserts the phases hold together: wire flip (#21) + crash rail (#22) +
// sampling (#25) all through one EdgeTelemetry.fromWiring graph, plus the
// public-API break-set compat half (#46/#47) and the <1ms event-record bar.
//
// What this file cannot gate (external, tracked in CHANGELOG [2.0.0]):
//   - Backend-team sign-off on the wire + accommodation asks (the ship gate).
//   - On-device native-crash e2e (device matrix, #29 deviation).

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
import 'package:edge_telemetry_flutter/src/managers/trace_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/test_identity.dart';

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

const _config = TelemetryConfig(
  serviceName: 'gate',
  endpoint: 'https://api.example.test',
);

/// Assemble the real facade over a recording sender. [batchSize] high by default
/// so batched events buffer until an explicit flush — lets us prove the
/// immediate rail fires on its own.
Future<(EdgeTelemetry, _RecordingSender, TelemetryWiring)> _facade({
  int batchSize = 100,
  Map<String, String>? global,
}) async {
  final sender = _RecordingSender();
  final session = SessionManager();
  await session.startSession('session_gate');
  final context = ContextManager(
    sessionManager: session,
    global: global ?? {'device.id': 'device_gate', 'user.id': 'user_gate'},
  );
  final transport = RetryTransport(
    endpoint: _config.endpoint,
    queue: _NoopQueue(),
    sender: sender.call,
  );
  final pipeline = Pipeline(
    identity: kTestIdentity,
    transport: transport,
    batchSize: batchSize,
  );
  final breadcrumbs = BreadcrumbManager();
  final collector = Collector(
    context: context,
    session: session,
    pipeline: pipeline,
    breadcrumbs: breadcrumbs,
  );
  final wiring = TelemetryWiring(
    config: _config,
    session: session,
    context: context,
    trace: TraceManager(session: session),
    breadcrumbs: breadcrumbs,
    crashReporting: const CrashReporting(),
    queue: _NoopQueue(),
    transport: transport,
    pipeline: pipeline,
    collector: collector,
    disposers: const [],
  );
  return (EdgeTelemetry.fromWiring(wiring), sender, wiring);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'cross-phase: batched event flushes as a canon telemetry_batch',
    () async {
      final (telemetry, sender, wiring) = await _facade(batchSize: 1);

      telemetry.trackEvent('demo.click', attributes: {'button': 'x'});
      await Future<void>(() {});

      expect(sender.sent, hasLength(1));
      final batch = sender.sent.single;
      expect(batch.keys.toList(), kR3EnvelopeKeys);
      expect(batch['type'], 'telemetry_batch');
      final event = (batch['events'] as List).single as Map;
      // Host name folds into the canon custom_event.
      expect(event['eventName'], 'custom.event');
      final attrs = event['attributes'] as Map;
      expect(attrs['event.name'], 'demo.click');
      expect(attrs.containsKey('device.id'), isFalse); // envelope only (R1)
      wiring.disposeAll();
    },
  );

  test(
    'cross-phase: trackError takes the batch rail, never the immediate one',
    () async {
      // batchSize 100 → nothing flushes by size; only the immediate rail sends on
      // its own, which since #90 a non-fatal no longer does.
      final (telemetry, sender, wiring) = await _facade();

      telemetry.trackEvent('buffered.event'); // buffers, no flush
      telemetry.trackError(StateError('boom'), stackTrace: StackTrace.current);
      await Future<void>(() {});

      // Nothing on the wire yet. The immediate rail exists for a dying process;
      // a handled error's process lives, so it rides the buffer and earns the
      // Pipeline's retries and the offline queue instead of one attempt.
      expect(sender.sent, isEmpty);

      wiring.pipeline.flush();
      await Future<void>(() {});

      // One payload, both items in it — not N single-attempt POSTs.
      expect(sender.sent, hasLength(1));
      final crash = sender.items.singleWhere(
        (i) => i['eventName'] == 'app.error',
      );
      final a = crash['attributes'] as Map;
      // Catalogue crash keys (#127).
      expect(a['error.message'], contains('boom'));
      expect(a['error.type'], 'StateError');
      expect(a['error.cause'], 'handled');
      expect(a.containsKey('is_fatal'), isFalse);
      expect(
        a.containsKey('crash_hash'),
        isFalse,
      ); // server-derived, never sent
      // v3 taxonomy (#90): inferred category, honesty flag, handled flag.
      expect(a['error.category'], 'unknown'); // StateError infers nothing
      expect(a['error.category_source'], 'inferred');
      wiring.disposeAll();
    },
  );

  test(
    'cross-phase: sampled-out session drops batched events, keeps the crash',
    () async {
      final (telemetry, sender, wiring) = await _facade(
        batchSize: 1,
        global: {
          'device.id': 'device_gate',
          'session.sampled': 'false', // rolled sampled-out
        },
      );

      telemetry.trackEvent('dropped.event'); // subject-to-sample → dropped
      telemetry.trackError(StateError('kept')); // bypass → survives
      await Future<void>(() {});

      expect(sender.items, hasLength(1));
      // Batched-but-bypass: batchSize 1 flushes it on its own.
      expect(sender.items.single['eventName'], 'app.error');
      wiring.disposeAll();
    },
  );

  test('public-API break set: the kept surface still compiles', () async {
    // The removals are enforced by the compiler — referencing startSpan,
    // endSpan, activeScreenSpans, runAppCallback (v2) or withSpan,
    // withNetworkSpan, useJsonFormat, batchTimeout, maxBatchSize,
    // eventBatchSize, enableCrashReporting, enableErrorReporting (v3) fails
    // the build. Here we assert the other half of that diff: the KEPT public
    // surface. These tear-offs stop building if a member is removed by
    // accident, which is the failure the break-set list cannot catch.
    final (telemetry, sender, wiring) = await _facade();

    final kept = <Function>[
      telemetry.trackEvent,
      telemetry.trackMetric,
      telemetry.trackError,
      telemetry.setUserProfile,
      telemetry.clearUserProfile,
      telemetry.addBreadcrumb,
    ];
    expect(kept, hasLength(6));
    expect(sender.sent, isEmpty);
    wiring.disposeAll();
  });

  test('perf: event-record stays under the 1ms Android bar', () async {
    final (telemetry, _, wiring) = await _facade();

    const n = 2000;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      wiring.collector.add(
        const EdgeEvent.event(
          'navigation',
          attributes: {'navigation.to_screen': '/x'},
        ),
      );
    }
    sw.stop();

    final perEventUs = sw.elapsedMicroseconds / n;
    // ponytail: asserts the median-record cost, not real HTTP (the sender is
    // faked). 1000us = the spec's 1ms bar; record path is ~single-digit us.
    expect(
      perEventUs,
      lessThan(1000),
      reason: '${perEventUs.toStringAsFixed(1)}us/event exceeds the 1ms bar',
    );
    wiring.disposeAll();
  });
}
