// test/unit/core/canon_drop_visibility_test.dart
//
// #79 second half: the allowlist drop stays a hard drop, but stops being a
// silent one. Drives real EdgeEvents through Collector → Pipeline → transport
// and asserts the dropped-item counter rides the `session.finalized` bookend on
// the wire — the seam that would have caught v2's seven silent drops.

import 'dart:async';

import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/core/wire_canon.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every off-canon name v2.0.0 actually emitted. All seven were written,
/// enriched, stringified and thrown away on every device for the whole of
/// v2 — found by audit, not by telemetry, because the drop was silent.
const _v2SilentDrops = <String, String>{
  'telemetry.initialized': 'event', // facade init
  'network.monitor_initialized': 'event', // NetworkCaptureHook
  'network.quality_score': 'metric', // NetworkCaptureHook
  'performance.monitor_initialized': 'event', // PerfCaptureHook
  'performance.startup_time': 'metric', // PerfCaptureHook
  'performance.system_check': 'event', // PerfCaptureHook
  'performance.memory_pressure': 'event', // PerfCaptureHook
};

class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];

  /// Wire items, unwrapped from their `telemetry_batch` envelope. Since #81
  /// both rails envelope — the immediate crash as a one-item batch.
  List<Map<String, dynamic>> get items => [
        for (final p in sent)
          ...?(p['events'] as List?)?.cast<Map<String, dynamic>>()
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const idle = Duration(minutes: 30);
  late DateTime clock;
  setUp(() => clock = DateTime(2026, 1, 1, 9, 0, 0));

  Future<(Collector, SessionManager, _RecordingSender)> wire({
    bool? sampledRoll,
    bool debugMode = false,
  }) async {
    final sender = _RecordingSender();
    var ids = 0;
    final session = SessionManager(
      newSessionId: () => 'session_${++ids}',
      clock: () => clock,
      idleTimeout: idle,
      sampledRoll: sampledRoll == null ? null : () => sampledRoll,
    );
    final context =
        ContextManager(sessionManager: session, global: {'device.id': 'd_1'});
    final pipeline = Pipeline(
      transport: RetryTransport(
          endpoint: 'https://api.example.test',
          queue: _NoopQueue(),
          sender: sender.call),
      batchSize: 100, // nothing flushes by size; only the immediate rail sends
    );
    final collector = Collector(
        context: context,
        session: session,
        pipeline: pipeline,
        debugMode: debugMode);
    session.bindSink(collector);
    await session.recoverAndStart();
    return (collector, session, sender);
  }

  /// The bookend as it lands on the wire. Bookends ride the immediate rail, so
  /// since #81 they arrive inside a one-item `telemetry_batch` envelope.
  Map<String, dynamic> finalizeOnWire(_RecordingSender s) =>
      s.items.lastWhere((p) => p['eventName'] == 'session.finalized');

  test('the canon holds exactly 16 events and 4 metrics', () {
    expect(kCanonEvents, hasLength(16));
    expect(kCanonMetrics, hasLength(4));

    // v3's four additions (#79).
    expect(
        kCanonEvents,
        containsAll([
          'ui.interaction',
          'frame.summary',
          'screen.load',
          'task.complete'
        ]));
    // Retained deprecate-in-place — the name never goes, only the emission.
    expect(kCanonEvents, containsAll(['user.interaction', 'screen.duration']));
    expect(
        kCanonMetrics, containsAll(['frame_render_time', 'resource_timing']));
    // Deliberately absent: unsupported by the backend, or already a `cause`.
    for (final name in [
      'memory_pressure',
      'storage_usage',
      'app.anr',
      'app.hang'
    ]) {
      expect(kCanonEvents, isNot(contains(name)),
          reason: '$name must stay off');
      expect(kCanonMetrics, isNot(contains(name)),
          reason: '$name must stay off');
    }
  });

  test('v2\'s seven silent drops are counted and ship on session.finalized',
      () async {
    final (collector, session, sender) = await wire();

    _v2SilentDrops.forEach((name, type) {
      collector.add(
          type == 'metric' ? EdgeEvent.metric(name, 1) : EdgeEvent.event(name));
    });
    await Future<void>(() {});

    // Still a hard drop: nothing off-canon reached the wire.
    expect(sender.sent.every((p) => p['eventName'] != 'telemetry.initialized'),
        isTrue);

    // Idle past the window → the next activity rotates and finalizes.
    clock = clock.add(idle + const Duration(minutes: 1));
    session.beforeEvent();
    await Future<void>(() {});

    final attrs = finalizeOnWire(sender)['attributes'] as Map;
    expect(attrs['session.dropped_item_count'], '7');
    expect(attrs['session.dropped_reasons'], 'off_canon=7');
  });

  test('a clean session reports zero and omits the reason breakdown', () async {
    final (collector, session, sender) = await wire();

    collector.add(const EdgeEvent.event('navigation',
        attributes: {'navigation.to': '/home'}));
    await Future<void>(() {});

    clock = clock.add(idle + const Duration(minutes: 1));
    session.beforeEvent();
    await Future<void>(() {});

    final attrs = finalizeOnWire(sender)['attributes'] as Map;
    expect(attrs['session.dropped_item_count'], '0');
    expect(attrs.containsKey('session.dropped_reasons'), isFalse);
  });

  test('the counter is per-session — a rotation resets it', () async {
    final (collector, session, sender) = await wire();

    collector.add(const EdgeEvent.event('off.canon.one'));
    clock = clock.add(idle + const Duration(minutes: 1));
    session.beforeEvent(); // finalizes session_1, starts session_2
    collector.add(const EdgeEvent.event('off.canon.two'));
    collector.add(const EdgeEvent.event('off.canon.three'));
    clock = clock.add(idle + const Duration(minutes: 1));
    session.beforeEvent(); // finalizes session_2
    await Future<void>(() {});

    final finals = sender.items
        .where((p) => p['eventName'] == 'session.finalized')
        .map((p) => (p['attributes'] as Map)['session.dropped_item_count'])
        .toList();
    expect(finals, ['1', '2']);
  });

  test('the counter takes any reason — later gates reuse it', () async {
    final (collector, session, sender) = await wire();

    collector.add(const EdgeEvent.event('off.canon'));
    session.recordDropped('tier_shed');
    session.recordDropped('tier_shed');
    session.recordDropped('action_cap');

    clock = clock.add(idle + const Duration(minutes: 1));
    session.beforeEvent();
    await Future<void>(() {});

    final attrs = finalizeOnWire(sender)['attributes'] as Map;
    expect(attrs['session.dropped_item_count'], '4');
    // Sorted by reason so the attribute is stable across runs.
    expect(attrs['session.dropped_reasons'],
        'action_cap=1,off_canon=1,tier_shed=2');
  });

  test('a sampled-out session still counts its drops — no confident zero',
      () async {
    // The finalize bookend bypasses sampling and ships this count, so the
    // allowlist gate must run even when the session lost the roll. Otherwise
    // the whole sampled-out population reports 0 drops it never looked at.
    final (collector, session, sender) = await wire(sampledRoll: false);

    _v2SilentDrops.forEach((name, type) {
      collector.add(
          type == 'metric' ? EdgeEvent.metric(name, 1) : EdgeEvent.event(name));
    });
    // A canon event in the same session is still sampled away, as before.
    collector.add(const EdgeEvent.event('navigation',
        attributes: {'navigation.to': '/home'}));

    clock = clock.add(idle + const Duration(minutes: 1));
    session.beforeEvent();
    await Future<void>(() {});

    final attrs = finalizeOnWire(sender)['attributes'] as Map;
    expect(attrs['session.sampled'], 'false');
    expect(attrs['session.dropped_item_count'], '7');
    expect(attrs['session.dropped_reasons'], 'off_canon=7');
  });

  test('debugMode names the dropped item; silent when off', () async {
    final logged = <String>[];
    final spy =
        ZoneSpecification(print: (_, __, ___, line) => logged.add(line));

    await runZoned(() async {
      final (collector, _, ignored) = await wire(debugMode: true);
      expect(ignored.items.map((p) => p['eventName']),
          everyElement(startsWith('session.')));
      collector.add(const EdgeEvent.event('performance.memory_pressure'));
      collector.add(const EdgeEvent.metric('network.quality_score', 4));
      collector.add(const EdgeEvent.event('navigation')); // canon → no log
    }, zoneSpecification: spy);

    final drops = logged.where((l) => l.contains('off-canon')).toList();
    expect(drops, hasLength(2));
    expect(drops[0], contains('performance.memory_pressure'));
    expect(drops[0], contains('event'));
    expect(drops[1], contains('network.quality_score'));
    expect(drops[1], contains('metric'));

    logged.clear();
    await runZoned(() async {
      final (collector, _, ignored) = await wire(); // debugMode off
      collector.add(const EdgeEvent.event('performance.memory_pressure'));
      expect(
          ignored.items.map((p) => p['eventName']),
          everyElement(
              startsWith('session.'))); // still a hard drop, logged or not
    }, zoneSpecification: spy);
    expect(logged.where((l) => l.contains('off-canon')), isEmpty);
  });

  test('a session killed mid-flight carries its drops into the next launch',
      () async {
    final (collector, session, _) = await wire();
    collector.add(const EdgeEvent.event('off.canon'));
    collector.add(const EdgeEvent.metric('off.canon.metric', 1));
    session.handlePause(); // persists the record; the OS then kills us

    // Next launch: a fresh manager recovers the persisted session.
    final sender = _RecordingSender();
    final recovered =
        SessionManager(newSessionId: () => 'session_next', clock: () => clock);
    final ctx =
        ContextManager(sessionManager: recovered, global: {'device.id': 'd_1'});
    final pipeline = Pipeline(
      transport: RetryTransport(
          endpoint: 'https://api.example.test',
          queue: _NoopQueue(),
          sender: sender.call),
      batchSize: 100,
    );
    recovered.bindSink(
        Collector(context: ctx, session: recovered, pipeline: pipeline));
    await recovered.recoverAndStart();
    await Future<void>(() {});

    final attrs = finalizeOnWire(sender)['attributes'] as Map;
    expect(attrs['session.recovered'], 'true');
    expect(attrs['session.dropped_item_count'], '2');
    expect(attrs['session.dropped_reasons'], 'off_canon=2');
  });
}
