// test/unit/core/attribute_policy_test.dart
//
// #85's privacy half at the Collector: the per-key cardinality cap and the one
// redaction hook. Both run over an item's **own** attributes and neither
// touches the context snapshot — asserted on the JSON that reaches the
// transport, not on the policy's internals.

import 'package:edge_telemetry_flutter/src/core/attribute_policy.dart';
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

  late DateTime clock;
  setUp(() => clock = DateTime(2026, 1, 1, 9, 0, 0));

  Future<(Collector, SessionManager, Pipeline, _RecordingSender)> wire({
    String? Function(String key, String value)? redact,
  }) async {
    final sender = _RecordingSender();
    var ids = 0;
    final session = SessionManager(
      newSessionId: () => 'session_${++ids}',
      clock: () => clock,
    );
    final context =
        ContextManager(sessionManager: session, global: {'device.id': 'd_1'});
    final pipeline = Pipeline(
      transport: RetryTransport(
          endpoint: 'https://api.example.test',
          queue: _NoopQueue(),
          sender: sender.call),
      batchSize: 1000,
    );
    final collector = Collector(
      context: context,
      session: session,
      pipeline: pipeline,
      // Bound exactly as `TelemetryWiring.build` binds it.
      policy: AttributePolicy(
          redact: redact, onCapped: session.recordCardinalityCap),
    );
    session.bindSink(collector);
    await session.recoverAndStart();
    return (collector, session, pipeline, sender);
  }

  Future<void> settle(Pipeline pipeline) async {
    pipeline.flush();
    await Future<void>.delayed(Duration.zero);
  }

  group('cardinality cap', () {
    test('the 51st distinct value is the sentinel, counted on its own key',
        () async {
      final (collector, _, pipeline, sender) = await wire();

      for (var i = 0; i < kCardinalityCap + 3; i++) {
        collector.add(EdgeEvent.event('custom_event',
            attributes: {'order': 'o$i'}, consumerAttributes: true));
      }
      await settle(pipeline);

      final orders = sender.items
          .where((e) => e['eventName'] == 'custom_event')
          .map((e) => (e['attributes'] as Map)['order'])
          .toList();

      expect(orders, hasLength(kCardinalityCap + 3));
      expect(orders.take(kCardinalityCap), everyElement(startsWith('o')));
      expect(orders.skip(kCardinalityCap),
          everyElement(equals(kCardinalitySentinel)));

      // Idle past the window, then let the next event rotate and finalize.
      clock = clock.add(const Duration(hours: 1));
      collector.add(const EdgeEvent.event('custom_event'));
      await settle(pipeline);

      final attrs = sender.items.lastWhere(
          (e) => e['eventName'] == 'session.finalized')['attributes'] as Map;
      expect(attrs['session.cardinality_capped_count'], '3');
      expect(attrs['session.dropped_item_count'], '0',
          reason: 'a replaced value is not a dropped item');
    });

    test('the allowance is per key, and starts fresh on rotation', () {
      final policy = AttributePolicy();
      for (var i = 0; i < kCardinalityCap + 1; i++) {
        policy
            .apply(<String, String>{'a': 'v$i'}, ['a'], consumerSupplied: true);
      }

      final other = <String, String>{'b': 'anything'};
      policy.apply(other, ['b'], consumerSupplied: true);
      expect(other['b'], 'anything', reason: 'a different key, a fresh 50');

      final capped = <String, String>{'a': 'one-more'};
      policy.apply(capped, ['a'], consumerSupplied: true);
      expect(capped['a'], kCardinalitySentinel);

      policy.reset();
      final afterRotation = <String, String>{'a': 'brand-new'};
      policy.apply(afterRotation, ['a'], consumerSupplied: true);
      expect(afterRotation['a'], 'brand-new');
    });

    test('the SDK\'s own per-item keys are never capped — http.url is',
        () async {
      final policy = AttributePolicy();
      // The request the ticket exists to measure, 60 times over.
      for (var i = 0; i < 60; i++) {
        final attrs = <String, String>{
          'http.url': 'https://api.test/v$i/thing',
          'http.timestamp': '2026-01-01T09:00:${i.toString().padLeft(2, '0')}Z',
          'http.duration_ms': '$i',
          'span.id': 'deadbeef0000$i',
        };
        policy.apply(attrs, attrs.keys, consumerSupplied: false);
        if (i < kCardinalityCap) continue;
        expect(attrs['http.url'], kCardinalitySentinel,
            reason: 'a REST app mints unbounded paths — that is what the cap '
                'and the templating are both for');
        expect(attrs['http.timestamp'], isNot(kCardinalitySentinel));
        expect(attrs['http.duration_ms'], isNot(kCardinalitySentinel));
        expect(attrs['span.id'], isNot(kCardinalitySentinel),
            reason: 'unique by design — capping it destroys the measurement '
                'the item exists to carry');
      }
    });

    test('the session bookends are out of scope entirely', () async {
      final seen = <String>[];
      final (collector, _, pipeline, sender) = await wire(redact: (k, v) {
        seen.add(k);
        return v;
      });
      await settle(pipeline);

      final started = sender.items.firstWhere(
          (e) => e['eventName'] == 'session.started')['attributes'] as Map;
      expect(started['session.id'], isNotNull);
      expect(seen, isEmpty,
          reason: 'a hook returning null here would orphan the whole session');
    });
  });

  group('the one redaction hook', () {
    test('rewrites an item attribute and can drop it outright', () async {
      String? redact(String key, String value) =>
          key == 'email' ? null : value.toUpperCase();
      final (collector, _, pipeline, sender) = await wire(redact: redact);

      collector.add(const EdgeEvent.event('custom_event',
          attributes: {'email': 'a@b.test', 'plan': 'gold'},
          consumerAttributes: true));
      await settle(pipeline);

      final attrs = sender.items
              .firstWhere((e) => e['eventName'] == 'custom_event')['attributes']
          as Map;
      expect(attrs.containsKey('email'), isFalse);
      expect(attrs['plan'], 'GOLD');
    });

    test('never runs over the SDK\'s own attributes', () async {
      final seen = <String>[];
      final (collector, _, pipeline, sender) = await wire(redact: (key, value) {
        seen.add(key);
        return null; // the careless hook: drop everything you do not know
      });

      collector.add(const EdgeEvent.event('http.request',
          attributes: {'http.url': 'https://api.test/x', 'span.id': 'abc'}));
      await settle(pipeline);

      expect(seen, isEmpty);
      final attrs = sender.items
              .firstWhere((e) => e['eventName'] == 'http.request')['attributes']
          as Map;
      expect(attrs['http.url'], 'https://api.test/x');
      expect(attrs['span.id'], 'abc');
    });

    test('never runs over the context snapshot', () async {
      final seen = <String>[];
      final (collector, _, pipeline, sender) = await wire(redact: (key, value) {
        seen.add(key);
        return value;
      });

      collector.add(const EdgeEvent.event('custom_event',
          attributes: {'own': '1'}, consumerAttributes: true));
      await settle(pipeline);

      expect(seen, ['own']);
      final attrs = sender.items
              .firstWhere((e) => e['eventName'] == 'custom_event')['attributes']
          as Map;
      expect(attrs['device.id'], 'd_1',
          reason: 'the SDK\'s own keys are its own');
      expect(attrs['session.id'], isNotNull);
    });
  });
}
