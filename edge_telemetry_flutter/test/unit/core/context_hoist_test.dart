// test/unit/core/context_hoist_test.dart
//
// The batch-context hoist wire seam (#82). Roughly 81% of every v2 item is
// repeated context; hoisting it to the batch is what every uncompressed ceiling
// in the budget depends on. It ships behind an internal constant because it
// fails *silently* against an unmerged processor — so these tests pin both the
// off state (byte-identical to v2) and the on state (an exact merge).

import 'dart:convert';

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

/// Records every envelope that would go on the wire.
class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];
  Future<bool> call(Map<String, dynamic> payload) async {
    sent.add(payload);
    return true;
  }
}

/// No-disk queue — nothing here exercises persistence.
class _NoopQueue extends OfflineQueue {
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> persist(Map<String, dynamic> payload,
          {bool isCrash = false}) async =>
      null;
}

/// One assembled stack: session → context → collector → recorded wire.
class _Rig {
  _Rig({required this.hoist, this.clock, this.idleTimeout}) {
    session = SessionManager(
      clock: clock,
      idleTimeout: idleTimeout ?? const Duration(minutes: 30),
      newSessionId: () => 'session_rotated',
    );
    context = ContextManager(
      sessionManager: session,
      global: {
        'device.id': 'device_1',
        'device.model': 'Pixel 9',
        'app.version': '3.0.0',
        'sdk.platform': 'flutter-android',
        'user.id': 'user_1',
        'tenant_hint': 'kept-per-item', // consumer global: never hoisted
      },
      networkType: 'wifi',
    );
    // batchSize 50 so only a context change can close a batch.
    pipeline = Pipeline(
      transport: RetryTransport(
          endpoint: 'https://example.test',
          queue: _NoopQueue(),
          sender: sender.call),
      batchSize: 50,
    );
    collector = Collector(
      context: context,
      session: session,
      pipeline: pipeline,
      hoistBatchContext: hoist,
    );
  }

  final bool hoist;
  final DateTime Function()? clock;
  final Duration? idleTimeout;
  final sender = _RecordingSender();
  late final SessionManager session;
  late final ContextManager context;
  late final Pipeline pipeline;
  late final Collector collector;

  List<Map<String, dynamic>> get batches => sender.sent;

  /// Attributes of the single batched item in the single flushed batch.
  Map<String, String> get soleItemAttributes =>
      ((batches.single['events'] as List).single
          as Map<String, dynamic>)['attributes'] as Map<String, String>;

  Map<String, String> get soleBatchContext =>
      (batches.single['context'] as Map?)?.cast<String, String>() ?? const {};
}

/// Key-sorted JSON — the canonical form of a JSONB attribute bag, so "the same
/// bytes" is a claim about content rather than about insertion order.
String _canonical(Map<String, String> bag) => jsonEncode(Map.fromEntries(
    bag.entries.toList()..sort((a, b) => a.key.compareTo(b.key))));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the flip ships off — nothing about the wire changes', () async {
    expect(kHoistBatchContext, isFalse,
        reason: 'flip only in the release after the processor merge lands');

    final rig = _Rig(hoist: false);
    await rig.session.startSession('session_a');
    rig.collector.add(const EdgeEvent.event('navigation'));
    rig.pipeline.flush();
    await Future<void>(() {});

    expect(rig.batches.single.containsKey('context'), isFalse);
    expect(rig.soleItemAttributes['session.id'], 'session_a');
    expect(rig.soleItemAttributes['device.id'], 'device_1');
    expect(rig.soleItemAttributes['session.event_count'], isNotNull);
  });

  /// The merge test, run once per wire-item shape (`event` / `metric`): both
  /// take the same batched path through `Pipeline.enqueue`, and a metric's bag
  /// is built by the same choke point, so both must merge back exactly.
  void mergesBackExactly(String label, EdgeEvent event) {
    test(
        'hoisted block + $label bag merges back to the un-hoisted bag, '
        'minus the mutable counters', () async {
      // Frozen clock + a reset prefs store, so the only difference between the
      // two runs is the hoist itself (start_time / total_sessions would drift).
      final frozen = DateTime(2026, 1, 1, 12);

      final plain = _Rig(hoist: false, clock: () => frozen);
      await plain.session.startSession('session_a');
      plain.collector.add(event);
      plain.pipeline.flush();

      SharedPreferences.setMockInitialValues({});
      final hoisted = _Rig(hoist: true, clock: () => frozen);
      await hoisted.session.startSession('session_a');
      hoisted.collector.add(event);
      hoisted.pipeline.flush();
      await Future<void>(() {});

      // The one deliberate difference: mutable counters leave the wire.
      final expected = Map<String, String>.from(plain.soleItemAttributes)
        ..removeWhere((k, _) => kMutableSessionCounters.contains(k));

      final merged = <String, String>{
        ...hoisted.soleBatchContext,
        ...hoisted.soleItemAttributes,
      };
      expect(merged, expected);
      // Byte-identical, not merely set-equal: the bag is a JSONB map on the
      // server, so key order is not part of its identity — canonicalise by
      // sorting, then compare the actual encoded bytes.
      expect(
          utf8.encode(_canonical(merged)), utf8.encode(_canonical(expected)));
      // Disjoint halves — no key is paid for twice, so no merge order matters.
      expect(
          merged,
          hasLength(hoisted.soleBatchContext.length +
              hoisted.soleItemAttributes.length));
    });
  }

  mergesBackExactly(
      'an event',
      const EdgeEvent.event('navigation',
          attributes: {'navigation.to': '/home', 'device.id': 'device_1'}));
  mergesBackExactly(
      'a metric',
      const EdgeEvent.metric('memory_usage', 42.0,
          attributes: {'metric.source': 'test'}));

  test('the block carries identity and the two batch-scoped live values',
      () async {
    final rig = _Rig(hoist: true);
    await rig.session.startSession('session_a');
    rig.collector.add(const EdgeEvent.event('navigation'));
    rig.pipeline.flush();
    await Future<void>(() {});

    final ctx = rig.soleBatchContext;
    expect(ctx['device.id'], 'device_1');
    expect(ctx['app.version'], '3.0.0');
    expect(ctx['sdk.platform'], 'flutter-android');
    expect(ctx['user.id'], 'user_1');
    expect(ctx['session.id'], 'session_a');
    expect(ctx['session.start_time'], isNotNull);
    expect(ctx['network.type'], 'wifi');
    expect(ctx['device.platform_brightness'], isNotNull);

    // Flat dotted spelling — the server-side merge is a plain map merge.
    expect(ctx.keys.every((k) => !k.contains('{') && k == k.trim()), isTrue);
    // An arbitrary consumer global stays per-item: it cannot be classified.
    expect(ctx.containsKey('tenant_hint'), isFalse);
    expect(rig.soleItemAttributes['tenant_hint'], 'kept-per-item');
  });

  test('mutable session counters leave the wire on batched items', () async {
    final rig = _Rig(hoist: true);
    await rig.session.startSession('session_a');
    rig.collector.add(const EdgeEvent.event('navigation'));
    rig.pipeline.flush();
    await Future<void>(() {});

    for (final counter in kMutableSessionCounters) {
      expect(rig.soleItemAttributes.containsKey(counter), isFalse,
          reason: '$counter must not ride a batched item');
      expect(rig.soleBatchContext.containsKey(counter), isFalse,
          reason: '$counter cannot be batch-scoped — it re-measures');
    }
  });

  test(
      'the session bookends keep their counters — the immediate rail is never '
      'hoisted', () async {
    final rig = _Rig(hoist: true);
    rig.session.bindSink(rig.collector);
    await rig.session.startSession('session_a');
    await Future<void>(() {});

    final started = rig.batches
        .expand((b) => (b['events'] as List).cast<Map<String, dynamic>>())
        .firstWhere((e) => e['eventName'] == 'session.started');
    final attrs = started['attributes'] as Map<String, String>;
    expect(attrs['session.id'], 'session_a');
    expect(attrs['session.event_count'], isNotNull);
    // One-item batch, no hoisted block.
    expect(rig.batches.every((b) => !b.containsKey('context')), isTrue);
  });

  test('a session rotation mid-batch produces two batches, never one',
      () async {
    var now = DateTime(2026, 1, 1, 12);
    final rig = _Rig(
      hoist: true,
      clock: () => now,
      idleTimeout: const Duration(minutes: 30),
    );
    await rig.session.startSession('session_a');

    rig.collector.add(const EdgeEvent.event('navigation'));
    now = now.add(const Duration(minutes: 31)); // idle past the window
    rig.collector.add(const EdgeEvent.event('navigation'));
    rig.pipeline.flush();
    await Future<void>(() {});

    final batched = rig.batches.where((b) => b.containsKey('context')).toList();
    expect(batched, hasLength(2));
    expect(batched[0]['context']['session.id'], 'session_a');
    expect(batched[1]['context']['session.id'], 'session_rotated');
    // Each batch is structurally one session.
    for (final b in batched) {
      expect(b['events'], hasLength(1));
    }
  });

  test('a user change mid-batch closes the batch too', () async {
    final rig = _Rig(hoist: true);
    await rig.session.startSession('session_a');

    rig.collector.add(const EdgeEvent.event('navigation'));
    rig.context.setGlobalAttribute('user.id', 'user_2');
    rig.collector.add(const EdgeEvent.event('navigation'));
    rig.pipeline.flush();
    await Future<void>(() {});

    expect(rig.batches, hasLength(2));
    expect(rig.batches[0]['context']['user.id'], 'user_1');
    expect(rig.batches[1]['context']['user.id'], 'user_2');
  });
}
