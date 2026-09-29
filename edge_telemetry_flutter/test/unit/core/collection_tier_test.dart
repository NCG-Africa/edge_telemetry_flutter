// test/unit/core/collection_tier_test.dart
//
// #80: the v3 config surface. Two fields — a tier dial and a capture override
// map — plus the budget governor that sheds whole tiers. The wire-seam half
// drives real EdgeEvents through Collector → Pipeline → transport, because the
// only honest assertion about shedding is what did and did not leave the device.

import 'dart:io';

import 'package:edge_telemetry_flutter/src/capture/capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/lifecycle_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/core/capture_gate.dart';
import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/config/collection_tier.dart';
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
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Collects EdgeEvents a capture hook emits — nothing reaches it unless the
/// hook actually built an attribute map.
class _FakeSink implements EventSink {
  final List<EdgeEvent> events = [];
  @override
  void add(EdgeEvent event) => events.add(event);
}

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
  Future<int> drain(
          Future<DrainResult> Function(Map<String, dynamic>) s) async =>
      0;
}

const _config = TelemetryConfig(
  serviceName: 'tier',
  endpoint: 'https://api.example.test',
);

/// Every wire item the sender saw, flattened out of its batch envelope.
List<Map<String, dynamic>> _items(_RecordingSender sender) => [
      for (final payload in sender.sent)
        if (payload['type'] == 'telemetry_batch')
          ...(payload['events'] as List).cast<Map<String, dynamic>>()
        else
          payload,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ==================== The enum is the decision ====================

  group('the Capture enum is closed at the essential boundary', () {
    test('has no crash, session, errors or profile member', () {
      // Not a gap in an enumeration — the decision itself. An SDK reporting no
      // crashes must never be indistinguishable from one configured not to, so
      // there is no off-switch and no escape hatch. Do not complete this for
      // symmetry; this test is the tripwire if someone tries.
      final names = Capture.values.map((c) => c.name).toSet();
      for (final forbidden in [
        'crash',
        'session',
        'errors',
        'error',
        'profile',
        'crashes',
        'sessions'
      ]) {
        expect(names, isNot(contains(forbidden)),
            reason: '$forbidden is essential — it has no switch');
      }
    });

    test('every member is standard or diagnostic, never essential', () {
      for (final c in Capture.values) {
        expect(c.tier, isNotNull, reason: '${c.name} has no tier');
        expect(c.tier, isNot(CollectionTier.essential));
      }
    });
  });

  // ==================== The two config fields ====================

  group('the tier dial', () {
    test('standard collects the standard set and none of the diagnostic set',
        () {
      for (final c in Capture.values) {
        expect(_config.capturesEnabled(c), c.tier == CollectionTier.standard,
            reason: c.name);
      }
    });

    test('essential sheds everything sheddable', () {
      const cfg = TelemetryConfig(
          serviceName: 't',
          endpoint: 'https://x.test',
          tier: CollectionTier.essential);
      expect(Capture.values.any(cfg.capturesEnabled), isFalse);
      expect(cfg.hasAutomaticMonitoring, isFalse);
    });

    test('diagnostic turns the opt-in set on as well', () {
      const cfg = TelemetryConfig(
          serviceName: 't',
          endpoint: 'https://x.test',
          tier: CollectionTier.diagnostic);
      expect(Capture.values.every(cfg.capturesEnabled), isTrue);
    });
  });

  group('the capture override map', () {
    test('works in both directions', () {
      const cfg = TelemetryConfig(
        serviceName: 't',
        endpoint: 'https://x.test',
        captureOverrides: {Capture.swipes: true, Capture.http: false},
      );
      expect(cfg.capturesEnabled(Capture.swipes), isTrue); // added above tier
      expect(cfg.capturesEnabled(Capture.http), isFalse); // removed below it
      expect(cfg.capturesEnabled(Capture.navigation), isTrue); // untouched
    });

    test('an override beats even tier: essential', () {
      const cfg = TelemetryConfig(
        serviceName: 't',
        endpoint: 'https://x.test',
        tier: CollectionTier.essential,
        captureOverrides: {Capture.http: true},
      );
      expect(cfg.capturesEnabled(Capture.http), isTrue);
      expect(cfg.capturesEnabled(Capture.navigation), isFalse);
    });
  });

  group('the deprecated booleans stay honoured as a fallback', () {
    test('a false legacy flag disables its capture', () {
      const cfg = TelemetryConfig(
        serviceName: 't',
        endpoint: 'https://x.test',
        // ignore: deprecated_member_use_from_same_package
        enableHttpMonitoring: false,
        // ignore: deprecated_member_use_from_same_package
        enablePerformanceMonitoring: false,
      );
      expect(cfg.capturesEnabled(Capture.http), isFalse);
      expect(cfg.capturesEnabled(Capture.frames), isFalse);
      expect(cfg.capturesEnabled(Capture.health), isFalse);
      expect(cfg.capturesEnabled(Capture.navigation), isTrue);
    });

    test('captureAccessibilityContext still opts into its diagnostic member',
        () {
      const cfg = TelemetryConfig(
        serviceName: 't',
        endpoint: 'https://x.test',
        // ignore: deprecated_member_use_from_same_package
        captureAccessibilityContext: true,
      );
      expect(cfg.capturesEnabled(Capture.accessibilityContext), isTrue);
      expect(cfg.capturesEnabled(Capture.swipes), isFalse);
    });

    test('the new key wins over the deprecated one', () {
      const cfg = TelemetryConfig(
        serviceName: 't',
        endpoint: 'https://x.test',
        // ignore: deprecated_member_use_from_same_package
        enableHttpMonitoring: false,
        captureOverrides: {Capture.http: true},
      );
      expect(cfg.capturesEnabled(Capture.http), isTrue);
    });
  });

  // ==================== Gating at the capture hook ====================

  group('tiers gate at the capture hook, before the attribute map', () {
    test('a running hook builds no map for a gated-off state', () {
      // The sharp version of the rule: LifecycleCaptureHook is *running* — the
      // session bridge is unconditional — and still emits nothing for a gated
      // state. This is the seam the rule exists for. Gating at the Collector
      // would have built the map, stringified the attributes, spent the CPU
      // and discarded the item; the sink proves nothing was built at all.
      final sink = _FakeSink();
      final hook = LifecycleCaptureHook(
        session: SessionManager(),
        flush: () {},
        gate: CaptureGate(_config), // standard tier: transitions are opt-in
      );
      hook.start(sink);
      addTearDown(() => WidgetsBinding.instance.removeObserver(hook));

      hook.didChangeAppLifecycleState(AppLifecycleState.inactive);
      hook.didChangeAppLifecycleState(AppLifecycleState.hidden);
      hook.didChangeAppLifecycleState(AppLifecycleState.detached);
      expect(sink.events, isEmpty); // Capture.lifecycleTransitions is off

      hook.didChangeAppLifecycleState(AppLifecycleState.paused);
      hook.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(sink.events, hasLength(2)); // Capture.lifecycle is on
      expect(sink.events.map((e) => e.attributes['lifecycle.state']),
          ['paused', 'resumed']);
    });

    test('a shed tier stops a hook that is already running', () {
      // The other half: the governor moves at runtime, so a hook started when
      // the budget was healthy must stop emitting once its tier is shed.
      final sink = _FakeSink();
      final gate = CaptureGate(_config.copyWith(
          captureOverrides: const {Capture.lifecycleTransitions: true}));
      final hook = LifecycleCaptureHook(
          session: SessionManager(), flush: () {}, gate: gate);
      hook.start(sink);
      addTearDown(() => WidgetsBinding.instance.removeObserver(hook));

      hook.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(sink.events, hasLength(1));

      for (var i = 0; i <= kDiagnosticShedCeiling; i++) {
        gate.recordItem();
      }
      hook.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(sink.events, hasLength(1)); // shed — nothing built
      hook.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(sink.events, hasLength(2)); // standard survives the first shed
    });

    test('a disabled capture is never even constructed', () {
      // The coarser, cheaper gate: TelemetryWiring simply does not call start()
      // on a hook whose capture is off, so it costs one branch at init and
      // nothing thereafter. HttpCaptureHook.start() installs
      // HttpOverrides.global, so an untouched global is proof it never ran.
      HttpOverrides.global = null;
      final session = SessionManager();
      return TelemetryWiring.build(
        config: _config.copyWith(tier: CollectionTier.essential),
        session: session,
        context: ContextManager(sessionManager: session, global: const {}),
        breadcrumbs: BreadcrumbManager(),
      ).then((wiring) {
        expect(HttpOverrides.current, isNull);
        expect(wiring.navigationObserver, isNull);
        expect(wiring.networkHook, isNull);
        wiring.disposeAll();
      });
    });
  });

  // ==================== The budget governor ====================

  group('the governor sheds whole tiers', () {
    CaptureGate gate() => CaptureGate(_config.copyWith(captureOverrides: const {
          Capture.swipes: true,
          Capture.longTask: true
        }));

    test('nothing is shed under the typical ceiling', () {
      final g = gate();
      for (var i = 0; i < kDiagnosticShedCeiling; i++) {
        g.recordItem();
      }
      expect(g.shedTier, isNull);
      expect(g.allows(Capture.swipes), isTrue);
      expect(g.allows(Capture.http), isTrue);
    });

    test('diagnostic sheds first, standard survives', () {
      final g = gate();
      for (var i = 0; i <= kDiagnosticShedCeiling; i++) {
        g.recordItem();
      }
      expect(g.shedTier, CollectionTier.diagnostic);
      expect(g.allows(Capture.swipes), isFalse);
      expect(g.allows(Capture.longTask), isFalse);
      expect(g.allows(Capture.http), isTrue);
      expect(g.allows(Capture.navigation), isTrue);
    });

    test('standard sheds second, and that is the whole order', () {
      final g = gate();
      for (var i = 0; i <= kStandardShedCeiling; i++) {
        g.recordItem();
      }
      expect(g.shedTier, CollectionTier.standard);
      expect(Capture.values.any(g.allows), isFalse);
    });

    test('the budget is per session — a rotation restores the allowance', () {
      final g = gate();
      for (var i = 0; i <= kStandardShedCeiling; i++) {
        g.recordItem();
      }
      g.resetBudget();
      expect(g.shedTier, isNull);
      expect(g.itemCount, 0);
      expect(g.allows(Capture.http), isTrue);
    });

    test('a consumer-disabled capture is not a shed and is not counted', () {
      var sheds = 0;
      final g = CaptureGate(
          _config.copyWith(captureOverrides: const {Capture.http: false}),
          onShed: () => sheds++);
      expect(g.allows(Capture.http), isFalse);
      expect(sheds, 0); // they chose it — nothing was dropped
    });
  });

  // ==================== Wire seams ====================

  group('wire seam', () {
    late _RecordingSender sender;
    late SessionManager session;
    late Collector collector;
    late Pipeline pipeline;
    late CaptureGate gate;
    late DateTime clock;

    setUp(() async {
      clock = DateTime(2026, 1, 1, 9, 0, 0);
      sender = _RecordingSender();
      session = SessionManager(clock: () => clock);
      final transport = RetryTransport(
          endpoint: _config.endpoint, queue: _NoopQueue(), sender: sender.call);
      pipeline = Pipeline(transport: transport, batchSize: 1);
      // Diagnostic members opted in, so a shed of them is a real shed: a
      // capture the consumer never enabled is not dropped, it was never on.
      gate = CaptureGate(
          _config.copyWith(captureOverrides: const {
            Capture.swipes: true,
            Capture.longTask: true,
          }),
          onShed: () => session.recordDropped('tier_shed'));
      session.onSessionStart = gate.resetBudget;
      collector = Collector(
        context: ContextManager(
            sessionManager: session, global: const {'device.id': 'd'}),
        session: session,
        pipeline: pipeline,
        gate: gate,
      );
      session.bindSink(collector);
      await session.startSession('session_tier');
      sender.sent.clear();
    });

    test('essential survives a full shed', () {
      // Tautological on purpose, and the tautology is the guarantee: `essential`
      // signals have no Capture member, so they never reach a gate at all and
      // there is no code path by which shedding could reach them. This pins
      // that structural fact — the day a crash *can* be gated, it fails.
      for (var i = 0; i <= kStandardShedCeiling; i++) {
        gate.recordItem();
      }
      expect(gate.shedTier, CollectionTier.standard);
      expect(Capture.values.any(gate.allows), isFalse); // everything sheddable

      collector.add(EdgeEvent.error(StateError('boom')));
      collector.add(const EdgeEvent.event('user.profile.update',
          attributes: {'user.id': 'u'}, bypassSampling: true));
      clock = clock.add(const Duration(minutes: 31));
      collector.add(const EdgeEvent.event('navigation',
          attributes: {'navigation.to': '/x'})); // triggers the rotation

      final names = _items(sender).map((e) => e['eventName']).toList();
      expect(names, contains('app.crash'));
      expect(names, contains('user.profile.update'));
      expect(names, contains('session.finalized'));
      expect(names, contains('session.started'));
    });

    test('every shed increments the dropped-item counter on the wire', () {
      for (var i = 0; i <= kDiagnosticShedCeiling; i++) {
        gate.recordItem();
      }
      gate.allows(Capture.swipes); // shed
      gate.allows(Capture.longTask); // shed
      gate.allows(Capture.http); // standard — survives, not counted

      clock = clock.add(const Duration(minutes: 31));
      collector.add(const EdgeEvent.event('navigation',
          attributes: {'navigation.to': '/x'}));

      final finalized = _items(sender)
          .firstWhere((e) => e['eventName'] == 'session.finalized');
      final attrs = finalized['attributes'] as Map<String, dynamic>;
      expect(attrs['session.dropped_reasons'], 'tier_shed=2');
      expect(attrs['session.dropped_item_count'], '2');
    });

    test('the generic calls stringify exactly as v2 did', () async {
      final telemetry = EdgeTelemetry.fromWiring(TelemetryWiring(
        config: _config,
        session: session,
        context: ContextManager(
            sessionManager: session, global: const {'device.id': 'd'}),
        breadcrumbs: BreadcrumbManager(),
        crashReporting: const CrashReporting(),
        queue: _NoopQueue(),
        transport: RetryTransport(
            endpoint: _config.endpoint,
            queue: _NoopQueue(),
            sender: sender.call),
        pipeline: pipeline,
        collector: collector,
        disposers: const [],
      ));

      // `Map<String, Object?>` in place of `dynamic`: the conversion already
      // stringified every value, so these call sites keep compiling and the
      // bytes on the wire do not move.
      telemetry.trackEvent('checkout', attributes: {
        'count': 3,
        'ratio': 1.5,
        'ok': true,
        'missing': null,
        'tags': ['a', 'b'],
        'at': DateTime.utc(2026, 1, 1),
        'took': const Duration(milliseconds: 250),
        'already': 'string',
        'nested': {'a': 1},
        'listOfLists': [
          [1, 2],
          [3],
        ],
      });
      // A canon metric name — an off-canon one is dropped by the allowlist,
      // which is #79's business, not this ticket's.
      telemetry.trackMetric('memory_usage', 12.0, attributes: {'retries': 2});
      await Future<void>(() {});

      final items = _items(sender);
      final event = items.firstWhere((e) => e['eventName'] == 'custom_event');
      expect(event['attributes'], containsPair('event.name', 'checkout'));
      expect(event['attributes'], containsPair('count', '3'));
      expect(event['attributes'], containsPair('ratio', '1.5'));
      expect(event['attributes'], containsPair('ok', 'true'));
      expect(event['attributes'], containsPair('missing', 'null'));
      expect(event['attributes'], containsPair('tags', 'a,b'));
      expect(
          event['attributes'], containsPair('at', '2026-01-01T00:00:00.000Z'));
      expect(event['attributes'], containsPair('took', '250'));
      expect(event['attributes'], containsPair('already', 'string'));
      expect(event['attributes'], containsPair('nested', '{a: 1}'));
      expect(event['attributes'], containsPair('listOfLists', '[1, 2],[3]'));

      final metric = items.firstWhere((e) => e['metricName'] == 'memory_usage');
      expect(metric['value'], 12.0);
      expect(metric['attributes'], containsPair('retries', '2'));
    });
  });
}
