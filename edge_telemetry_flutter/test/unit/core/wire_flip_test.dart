// test/unit/core/wire_flip_test.dart
//
// The Phase-3 wire flip (#21): the assembled batch must match the family canon.
// Drives real EdgeEvents through Collector → Pipeline → transport and snapshots
// the envelope, allowlist filtering, http folding, metric renames, device.id
// presence, and the geo/tenant strip.

import 'dart:convert';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
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

/// Build a Collector wired to a recording sender; [flushAt] events per batch.
Future<(Collector, _RecordingSender)> _wire({
  int flushAt = 100,
  Map<String, String>? global,
  String endpoint = 'https://api.example.test',
  String? apiKey,
}) async {
  final sender = _RecordingSender();
  final session = SessionManager();
  await session.startSession('session_test');
  final context = ContextManager(
    sessionManager: session,
    global: global ?? {'device.id': 'device_abc', 'user.id': 'user_abc'},
  );
  final transport = RetryTransport(
      endpoint: endpoint,
      apiKey: apiKey,
      queue: _NoopQueue(),
      sender: sender.call);
  final pipeline = Pipeline(transport: transport, batchSize: flushAt);
  final collector =
      Collector(context: context, session: session, pipeline: pipeline);
  return (collector, sender);
}

/// Normalize an assembled batch for golden comparison: blank the volatile
/// timestamps and drop the session.*/network.* attrs (owned by #9) plus the
/// live device-context keys (`device.platform_brightness` — owned by #26), none
/// of which the wire-flip canon (#21) this fixture pins is concerned with.
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

  test('batch envelope matches canon: telemetry_batch + fields + device.id',
      () async {
    final (collector, sender) = await _wire(flushAt: 2);

    collector.add(const EdgeEvent.event('navigation',
        attributes: {'navigation.to': '/home'}));
    collector.add(const EdgeEvent.metric('frame_render_time', 12.5));
    await Future<void>(() {});

    expect(sender.sent, hasLength(1));
    final batch = sender.sent.single;
    expect(batch.keys.toList(), ['type', 'timestamp', 'batch_size', 'events']);
    expect(batch['type'], 'telemetry_batch');
    expect(batch['batch_size'], 2);

    final events = (batch['events'] as List).cast<Map<String, dynamic>>();
    expect(events.map((e) => e['eventName'] ?? e['metricName']),
        ['navigation', 'frame_render_time']);
    // device.id rides in every event's attributes (Collector 400s without it).
    for (final e in events) {
      expect((e['attributes'] as Map)['device.id'], 'device_abc');
    }
    // The metric keeps metricName + value at root (shape unchanged).
    expect(events[1]['metricName'], 'frame_render_time');
    expect(events[1]['value'], 12.5);
  });

  test('allowlist gate: canon kept, noise + folded http + dropped metrics out',
      () async {
    final (collector, sender) = await _wire(flushAt: 1);

    // Non-canon → all dropped, nothing flushes.
    collector.add(const EdgeEvent.event('telemetry.initialized'));
    collector.add(const EdgeEvent.event('http.error'));
    collector.add(const EdgeEvent.event('http.slow_request'));
    collector.add(const EdgeEvent.event('performance.memory_pressure'));
    collector.add(const EdgeEvent.metric('http.response_time', 1));
    collector.add(const EdgeEvent.metric('network.quality_score', 4));
    collector.add(const EdgeEvent.metric('performance.startup_time', 1));
    await Future<void>(() {});
    expect(sender.sent, isEmpty);

    // Canon http.request survives (the fold target).
    collector.add(const EdgeEvent.event('http.request',
        attributes: {'http.success': 'true'}));
    await Future<void>(() {});
    expect(sender.sent, hasLength(1));
    expect((sender.sent.single['events'] as List).single['eventName'],
        'http.request');
  });

  test('geo/tenant never reach the wire — from globals OR event attributes',
      () async {
    final (collector, sender) = await _wire(flushAt: 1, global: {
      'device.id': 'device_abc',
      'location': 'Nairobi', // global path
      'tenant_id': 't_1',
    });

    // geo arrives via event attributes — must still be stripped (the merge in
    // Collector.add spreads event.attributes over the snapshot).
    collector
        .add(const EdgeEvent.event('navigation', attributes: {'geo': 'KE'}));
    await Future<void>(() {});

    final attrs =
        (sender.sent.single['events'] as List).single['attributes'] as Map;
    expect(attrs['device.id'], 'device_abc');
    expect(attrs.containsKey('location'), isFalse);
    expect(attrs.containsKey('tenant_id'), isFalse);
    expect(attrs.containsKey('geo'), isFalse);
  });

  test('assembled batch matches the family-canon golden fixture', () async {
    final (collector, sender) = await _wire(flushAt: 2);
    collector.add(const EdgeEvent.event('navigation',
        attributes: {'navigation.to': '/home'}));
    collector.add(const EdgeEvent.metric('frame_render_time', 12.5));
    await Future<void>(() {});

    final golden = (jsonDecode(
            File('test/fixtures/canon_telemetry_batch.json').readAsStringSync())
        as Map<String, dynamic>)
      ..remove('_comment');

    expect(_normalize(sender.sent.single), golden);
  });

  test('transport resolves <endpoint>/collector/telemetry (base or suffixed)',
      () {
    Uri url(String endpoint) =>
        RetryTransport(endpoint: endpoint, queue: _NoopQueue()).resolvedUrl;

    expect(url('https://api.example.test').toString(),
        'https://api.example.test/collector/telemetry');
    // Trailing slash is not doubled.
    expect(url('https://api.example.test/').toString(),
        'https://api.example.test/collector/telemetry');
    // Already-canon path is left intact (not double-appended).
    expect(url('https://api.example.test/collector/telemetry').toString(),
        'https://api.example.test/collector/telemetry');
  });
}
