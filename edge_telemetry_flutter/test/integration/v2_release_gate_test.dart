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

import 'dart:convert';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/config/telemetry_config.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/core/wire_canon.dart';
import 'package:edge_telemetry_flutter/src/crash/crash_reporting.dart';
import 'package:edge_telemetry_flutter/src/facade/edge_telemetry.dart';
import 'package:edge_telemetry_flutter/src/facade/telemetry_wiring.dart';
import 'package:edge_telemetry_flutter/src/managers/breadcrumb_manager.dart';
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
  Future<String?> persist(Map<String, dynamic> p,
          {bool isCrash = false}) async =>
      null;
  @override
  Future<int> drain(Future<bool> Function(Map<String, dynamic>) s) async => 0;
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
      endpoint: _config.endpoint, queue: _NoopQueue(), sender: sender.call);
  final pipeline = Pipeline(transport: transport, batchSize: batchSize);
  final breadcrumbs = BreadcrumbManager();
  final collector = Collector(
      context: context,
      session: session,
      pipeline: pipeline,
      breadcrumbs: breadcrumbs);
  final wiring = TelemetryWiring(
    config: _config,
    session: session,
    context: context,
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

/// Blank the volatile timestamps and drop the session.*/network.* + live
/// device-context keys the wire-flip canon fixture doesn't pin (same normalize
/// as wire_flip_test — those attrs are #9/#26's concern, not the envelope).
Map<String, dynamic> _normalize(Map<String, dynamic> batch) => {
      ...batch,
      'timestamp': '<TS>',
      'events': (batch['events'] as List).map((e) {
        final ev = Map<String, dynamic>.from(e as Map);
        ev['timestamp'] = '<TS>';
        ev['attributes'] = Map<String, dynamic>.from(ev['attributes'] as Map)
          ..removeWhere((k, _) =>
              k.startsWith('session.') ||
              k.startsWith('network.') ||
              k == 'device.platform_brightness' ||
              k == 'device.text_scale_factor' ||
              k == 'device.reduce_motion');
        return ev;
      }).toList(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('cross-phase: batched event flushes as a canon telemetry_batch',
      () async {
    final (telemetry, sender, wiring) = await _facade(batchSize: 1);

    telemetry.trackEvent('demo.click', attributes: {'button': 'x'});
    await Future<void>(() {});

    expect(sender.sent, hasLength(1));
    final batch = sender.sent.single;
    expect(batch.keys.toList(), ['type', 'timestamp', 'batch_size', 'events']);
    expect(batch['type'], 'telemetry_batch');
    final event = (batch['events'] as List).single as Map;
    // Host name folds into the canon custom_event.
    expect(event['eventName'], 'custom_event');
    final attrs = event['attributes'] as Map;
    expect(attrs['event.name'], 'demo.click');
    expect(attrs['device.id'], 'device_gate');
    wiring.disposeAll();
  });

  test('e2e wire snapshot: assembled stack matches the family-canon fixture',
      () async {
    // The system-level counterpart to wire_flip_test's collector-level golden:
    // drive canon events through the full TelemetryWiring (breadcrumbs, real
    // Pipeline/RetryTransport) and snapshot the assembled batch vs the fixture.
    final (_, sender, wiring) = await _facade(
        batchSize: 2,
        global: {'device.id': 'device_abc', 'user.id': 'user_abc'});

    wiring.collector.add(const EdgeEvent.event('navigation',
        attributes: {'navigation.to': '/home'}));
    wiring.collector.add(const EdgeEvent.metric('frame_render_time', 12.5));
    await Future<void>(() {});

    final golden = (jsonDecode(
            File('test/fixtures/canon_telemetry_batch.json').readAsStringSync())
        as Map<String, dynamic>)
      ..remove('_comment');
    expect(_normalize(sender.sent.single), golden);
    wiring.disposeAll();
  });

  test(
      'accommodation validator: orphan events ride the wire (backend fallback)',
      () async {
    // #30 backend-accommodation ask: these 5 orphan events are emitted now with
    // no config gate — they must reach the wire (they land in the generic
    // rum_performance_events fallback until the backend adds handlers). Pin them
    // to the canon allowlist so they're never accidentally dropped at the gate.
    const orphans = {
      'page_load',
      'app_lifecycle',
      'user.interaction',
      'custom_event',
      'network_change',
    };
    expect(orphans.every(kCanonEvents.contains), isTrue,
        reason: 'orphan events must stay on the wire allowlist');
  });

  test('cross-phase: trackError fires the immediate app.crash rail on its own',
      () async {
    // batchSize 100 → a batched event will NOT flush; only the immediate rail can.
    final (telemetry, sender, wiring) = await _facade();

    telemetry.trackEvent('buffered.event'); // buffers, no flush
    telemetry.trackError(StateError('boom'), stackTrace: StackTrace.current);
    await Future<void>(() {});

    // Exactly one payload on the wire — the crash — while the event still
    // buffers. Crashes ride the immediate rail as a bare event (not wrapped in a
    // telemetry_batch envelope; that's the batched rail).
    expect(sender.sent, hasLength(1));
    final crash = sender.sent.single;
    expect(crash['eventName'], 'app.crash');
    final a = crash['attributes'] as Map;
    // Unprefixed payload keys the rum_crash_events extractors read verbatim.
    expect(a['message'], contains('boom'));
    expect(a['exception_type'], 'StateError');
    expect(a['cause'], 'Error');
    expect(a['is_fatal'], 'false');
    expect(a.containsKey('crash_hash'), isFalse); // server-derived, never sent

    // The buffered event is still pending; a flush drains it separately.
    wiring.pipeline.flush();
    await Future<void>(() {});
    expect(sender.sent, hasLength(2));
    wiring.disposeAll();
  });

  test('cross-phase: sampled-out session drops batched events, keeps the crash',
      () async {
    final (telemetry, sender, wiring) = await _facade(batchSize: 1, global: {
      'device.id': 'device_gate',
      'session.sampled': 'false', // rolled sampled-out
    });

    telemetry.trackEvent('dropped.event'); // subject-to-sample → dropped
    telemetry.trackError(StateError('kept')); // bypass → survives
    await Future<void>(() {});

    expect(sender.sent, hasLength(1));
    expect(sender.sent.single['eventName'], 'app.crash'); // immediate rail
    wiring.disposeAll();
  });

  test('public-API break set: deprecated span no-ops run and record nothing',
      () async {
    // The 4 hard-removed symbols (startSpan/endSpan/activeScreenSpans/
    // runAppCallback) are enforced by the compiler — referencing one fails the
    // build. Here we assert the compat half: the 3 kept no-ops still execute
    // their operation and emit no telemetry.
    final (telemetry, sender, wiring) = await _facade();

    // ignore: deprecated_member_use_from_same_package
    final r1 = await telemetry.withSpan('op', () async => 42);
    // ignore: deprecated_member_use_from_same_package
    final r2 = await telemetry.withNetworkSpan(
        'op', 'https://x', 'GET', () async => 7);
    await Future<void>(() {});

    expect(r1, 42);
    expect(r2, 7);
    expect(sender.sent, isEmpty); // no span → no wire traffic

    // Compile-time guard on the KEPT public surface ("your code mostly didn't
    // change"): these tear-offs fail to build if a member is accidentally
    // removed, catching the other half of the break-set diff the compiler
    // already enforces for the 4 removals.
    final kept = <Function>[
      telemetry.trackEvent,
      telemetry.trackMetric,
      telemetry.trackError,
      telemetry.setUserProfile,
      telemetry.clearUserProfile,
      telemetry.addBreadcrumb,
    ];
    expect(kept, hasLength(6));
    wiring.disposeAll();
  });

  test('perf: event-record stays under the 1ms Android bar', () async {
    final (telemetry, _, wiring) = await _facade();

    const n = 2000;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      wiring.collector.add(const EdgeEvent.event('navigation',
          attributes: {'navigation.to': '/x'}));
    }
    sw.stop();

    final perEventUs = sw.elapsedMicroseconds / n;
    // ponytail: asserts the median-record cost, not real HTTP (the sender is
    // faked). 1000us = the spec's 1ms bar; record path is ~single-digit us.
    expect(perEventUs, lessThan(1000),
        reason: '${perEventUs.toStringAsFixed(1)}us/event exceeds the 1ms bar');
    wiring.disposeAll();
  });
}
