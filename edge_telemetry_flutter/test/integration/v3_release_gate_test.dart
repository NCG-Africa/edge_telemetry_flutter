// test/integration/v3_release_gate_test.dart
//
// The v3 release gate (#94), mirroring v2's (`v2_release_gate_test.dart`) and
// adding the half v2 had no need of: the **budget**. A ceiling that nothing
// enforces is an aspiration, so the two reference sessions from the spec are
// driven through the assembled graph and their items and bytes are counted
// against the published ceilings.
//
// The default allocation lands with **no slack left**. From v3 on, a new
// default-on signal has to be traded for an existing one, and this file is
// where that trade becomes visible instead of theoretical: add an emitter and
// the typical-session assertion fails with the new count in the message.
//
// As measured by this file on the shipped v3.0.0 graph:
//
//   typical  90 items · 104,105 bytes · 6,619 gzipped   (ceilings 250 / 120 KB / 15 KB)
//   heavy   419 items · 571,268 bytes · 20,365 gzipped  (ceilings 1,200 / 600 KB / 75 KB)
//
// The typical session's 90 items are: 1 `session.started`, 1 `page_load`, 8
// `navigation`, 8 `screen.load`, 40 `http.request`, 25 `ui.interaction`, 2
// `app_lifecycle`, 2 `memory_usage` bookends, 2 `frame.summary` (the reservoir's
// cap, not a count of windows) and 1 `session.finalized`. **The heavy session's
// uncompressed figure sits at 93% of its ceiling** — that is what no slack
// means, and it is why the next default signal is a trade.
//
// The stack here is the real one. `TelemetryWiring.build` assembles it — not a
// hand-wired copy, because a gate that wires its own hooks asserts its own
// arithmetic — and every test runs under `testWidgets`, which is the only place
// a pointer gesture actually dispatches: under a plain `test()` the global
// pointer route never reaches the action hook, so a budget measured there would
// silently be missing all 25 of the typical session's `ui.interaction` items.
//
// `testWidgets` runs in fake async, where a real POST never completes, so the
// transport's one injectable seam (`sender`) records payloads instead. Bytes are
// then measured **exactly as `RetryTransport` measures them** —
// `utf8.encode(jsonEncode(payload))`, then `GZipCodec().encode` — so the wire
// figure is the bytes the transport would have written, not an estimate of
// them.
//
// ## What this gate cannot cover
//
//   - **Backend sign-off on the family change-request packet (#77).** The
//     bag-first JSONB proposal is the backend-side companion to v3; it is
//     tracked there, and no device-side test can stand in for another team's
//     acceptance. A green gate here says the SDK ships what it promised, not
//     that the server stores it.
//   - **On-device native crash end to end.** MetricKit delivers next-launch and
//     `ApplicationExitInfo` needs a real process death, so the seam is mocked
//     at the channel here (as v2's gate mocked its own) and the real thing
//     needs the device matrix.
//
// ## What this gate deliberately does not assert
//
//   - **The per-frame overhead ceiling** and **the native memory-read cost**.
//     Both need a device and a profiler. A microsecond threshold green on a
//     shared CI runner would fail for reasons unrelated to the code — a noisy
//     neighbour, a cold JIT, a throttled container — and a flaky gate gets
//     disabled, which is worse than an absent one. The per-frame cost is
//     bounded by inspection instead (`FrameCaptureHook.recordFrame`: three
//     divisions, four comparisons, three max updates, one increment, no
//     allocation), and the memory read is two calls a session.
//
// The event-record bar *is* asserted, as in v2 — 1 ms is three orders of
// magnitude above the real cost, so runner noise cannot reach it.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:edge_telemetry_flutter/src/capture/frame_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/core/capture_gate.dart';
import 'package:edge_telemetry_flutter/src/core/config/collection_tier.dart';
import 'package:edge_telemetry_flutter/src/core/config/telemetry_config.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/core/sdk_version.dart';
import 'package:edge_telemetry_flutter/src/crash/native_crash_channel.dart';
import 'package:edge_telemetry_flutter/src/facade/edge_telemetry.dart';
import 'package:edge_telemetry_flutter/src/facade/telemetry_wiring.dart';
import 'package:edge_telemetry_flutter/src/managers/breadcrumb_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/trace_manager.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// The published ceilings (#49 §3, restated in the spec's Testing Decisions).
// ---------------------------------------------------------------------------

/// Typical: 10 min, 8 screens, 40 requests, 25 actions.
const int kTypicalItemCeiling = 250;
const int kTypicalByteCeiling = 120 * 1024;
const int kTypicalWireCeiling = 15 * 1024;

/// Heavy: 45 min, 30 screens, 200 requests, 150 actions.
const int kHeavyItemCeiling = 1200;
const int kHeavyByteCeiling = 600 * 1024;
const int kHeavyWireCeiling = 75 * 1024;

/// The default configuration's share of the typical ceiling. Not a target the
/// SDK aims at — the allocation landed here, and the headroom is what pays for
/// the next signal.
const double kDefaultBudgetShare = 0.40;

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// Records what the transport would have sent, and costs it.
///
/// Byte accounting mirrors `RetryTransport` exactly: the payload is JSON-encoded
/// to UTF-8 for the uncompressed figure and gzipped for the wire figure. Both
/// rails come through here, so a fatal crash's one-item batch is costed too.
class _Recorder {
  final List<Map<String, dynamic>> batches = [];
  int uncompressedBytes = 0;
  int wireBytes = 0;

  Future<bool> call(Map<String, dynamic> payload) async {
    batches.add(payload);
    final body = utf8.encode(jsonEncode(payload));
    uncompressedBytes += body.length;
    wireBytes += gzip.encode(body).length;
    return true;
  }

  /// Every wire item, unwrapped from its `telemetry_batch` envelope. Both rails
  /// envelope since #81, so a fatal crash is a one-item batch here too.
  List<Map<String, dynamic>> get items => [
    for (final b in batches)
      ...?(b['events'] as List?)?.cast<Map<String, dynamic>>(),
  ];

  /// Items belonging to [sessionId]. The reference session is closed by a
  /// rotation, which necessarily starts a successor — counting by `session.id`
  /// is what keeps the successor's bookends out of the budget.
  List<Map<String, dynamic>> itemsFor(String sessionId) => [
    for (final i in items)
      if (((i['attributes'] as Map?)?['session.id']) == sessionId) i,
  ];

  /// An item's canon name. Events carry `eventName` and metrics `metricName` —
  /// the wire keeps them apart, so anything counting items has to ask for both
  /// or it silently loses every metric.
  static String? nameOf(Map<String, dynamic> item) =>
      (item['eventName'] ?? item['metricName']) as String?;
}

/// The assembled stack, plus the handles a driver needs to move it.
class _Gate {
  _Gate({
    required this.telemetry,
    required this.wiring,
    required this.recorder,
    required this.session,
    required this.advance,
  });

  final EdgeTelemetry telemetry;
  final TelemetryWiring wiring;
  final _Recorder recorder;
  final SessionManager session;

  /// Moves the injected clock. The session model is lazy — no timers — so idle
  /// rotation is only reachable by advancing a clock and then poking it.
  final void Function(Duration) advance;

  String get sessionId => session.currentSessionId!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late _Recorder recorder;
  late DateTime now;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(NativeCrashChannel.channelName);

  /// Calls the native seam saw. The device-state read is the #91 extension to
  /// the existing crash-drain mock — one channel, two methods, so the gate's
  /// mock answers both or the memory bookends silently report nothing.
  late List<String> nativeCalls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('v3_gate_');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    now = DateTime.utc(2026, 9, 30, 9);
    RetryTransport.resetGzipProbe();
    nativeCalls = [];
    recorder = _Recorder();

    // connectivity_plus, mocked so `NetworkCaptureHook` initializes instead of
    // reporting its own MissingPluginException. Not cosmetic: the unmocked
    // stream throws asynchronously, `testWidgets` reports that as a test
    // failure, and the SDK-internal `app.crash` it produces would sit in the
    // budget as an item no real install emits.
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (_, sink) => sink.success(<String>['wifi']),
      ),
    );

    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      switch (call.method) {
        case 'drainNativeCrashes':
          return <dynamic>[];
        case 'readDeviceState':
          // The bookend reads two of these; the five fault-bundle keys are
          // fatal-only and ride the crash payload, never a bookend. Returned
          // here anyway, because the contract is one map for both callers.
          return <String, dynamic>{
            'memory.used_bytes': '104857600',
            'memory.source': 'pss',
            'device.battery_level': '0.62',
            'device.battery_charging': 'false',
            'device.power_save_mode': 'false',
            'device.thermal_state': 'nominal',
            'device.orientation': 'portrait',
          };
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      null,
    );
    // The directory is deliberately left for the OS to reap. Work started inside
    // `tester.runAsync` (a queue write behind a flush) can still be in flight
    // when the test body returns, and deleting the docs dir under it throws
    // after the test has completed — which surfaces as a failure on the *next*
    // test rather than this one.
  });

  /// Build and start the real graph over the recording sender.
  ///
  /// [batchSize] is deliberately huge: the budget is a per-session count, so
  /// nothing should flush on size and split a session across a boundary the
  /// driver then has to reason about. Flushes are explicit.
  Future<_Gate> gate(
    WidgetTester tester, {
    CollectionTier tier = CollectionTier.standard,
    Map<Capture, bool> overrides = const {},
    int batchSize = 100000,
  }) async {
    final config = TelemetryConfig(
      serviceName: 'v3-gate',
      endpoint: 'https://collector.example.test',
      apiKey: 'gate-key',
      batchSize: batchSize,
      // Far past any test's runtime: a timer-driven flush mid-assertion would
      // make the byte counts depend on wall-clock scheduling.
      flushIntervalMs: 600000,
      tier: tier,
      captureOverrides: overrides,
    );

    // Construction order is strict and silent when wrong: session → trace →
    // context. Asserted by being written down, as the facade writes it down.
    final session = SessionManager(clock: () => now);
    final trace = TraceManager(session: session, clock: () => now);
    final context = ContextManager(
      sessionManager: session,
      trace: trace,
      global: {'device.id': 'device_gate', 'user.id': 'user_gate'},
      captureAccessibilityContext: config.capturesEnabled(
        Capture.accessibilityContext,
      ),
    );
    final breadcrumbs = BreadcrumbManager();

    // `runAsync` for both: the queue creates a real directory and the session
    // record is a real `shared_preferences` round trip, and `testWidgets` runs
    // in fake async where neither future ever completes.
    final wiring =
        (await tester.runAsync(
          () => TelemetryWiring.build(
            config: config,
            session: session,
            context: context,
            trace: trace,
            breadcrumbs: breadcrumbs,
            sender: recorder.call,
          ),
        ))!;
    await tester.runAsync(session.recoverAndStart);
    // A real tree, so the framework's warm-up frame runs *inside* the test body.
    // `PerfCaptureHook` reports `page_load` from a post-frame callback; without
    // this the callback fires during the framework's own teardown pump, after
    // `disposeAll`, and leaves the pipeline's flush timer pending.
    await tester.pumpWidget(const SizedBox.shrink());
    trace.mint(TraceRootType.launch);

    return _Gate(
      telemetry: EdgeTelemetry.fromWiring(wiring),
      wiring: wiring,
      recorder: recorder,
      session: session,
      advance: (d) => now = now.add(d),
    );
  }

  /// Drive one reference session's worth of real activity, then close it.
  ///
  /// Everything here goes through the hook `TelemetryWiring.build` started —
  /// the navigation observer, the screen-load hook behind it, the wrapped
  /// `package:http` client, the global pointer route, the frame timings
  /// callback and the lifecycle observer. Nothing is emitted straight at the
  /// Collector, because an item the hooks would never build is not budget.
  Future<void> driveReferenceSession(
    WidgetTester tester,
    _Gate g, {
    required int screens,
    required int requests,
    required int actions,
    required Duration span,
  }) async {
    final observer = g.telemetry.navigationObserver;
    final client = g.telemetry.captureClient(
      MockClient(
        (_) async => http.Response(
          '{"ok":true}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    Route<void> route(String name) => MaterialPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => const SizedBox.shrink(),
    );

    // Screens, each settled — an unsettled screen terminates on a deadline the
    // gate has no clock authority over, and would make the count depend on it.
    Route<void>? previous;
    for (var i = 0; i < screens; i++) {
      final next = route('/screen$i');
      observer.didPush(next, previous);
      g.telemetry.reportScreenSettled();
      previous = next;
    }

    // Requests, spread over the screens so each one lands inside a real screen
    // and a real trace root rather than all on the last.
    await tester.runAsync(() async {
      for (var i = 0; i < requests; i++) {
        await client.get(Uri.parse('https://api.example.test/v1/items/$i'));
      }
    });
    await tester.pump();

    // Actions, through the real global pointer route.
    for (var i = 0; i < actions; i++) {
      _tap(i, at: Duration(milliseconds: 100 * i));
    }

    // Frames. The reservoir keeps the worst two windows per session however
    // many are closed, which is the property the budget depends on — so the
    // driver closes more than two on purpose.
    final frames = g.wiring.frameHook;
    if (frames != null) {
      for (var window = 0; window < 4; window++) {
        final base = window * kFrameWindowCap.inMicroseconds;
        for (var f = 0; f < 30; f++) {
          // Two janky frames per window. A window with no slow frame is
          // deliberately ineligible — a smooth session emits no `frame.summary`
          // at all — so a driver that only produced smooth frames would leave
          // the two items the spec allocates out of the budget entirely.
          final slow = f % 15 == 0;
          frames.recordFrame(
            _timing(
              atMicros: base + f * 16000,
              buildMs: slow ? 18 : 4,
              rasterMs: slow ? 12 : 5,
            ),
          );
        }
        // Past the window cap → the open window closes into the reservoir.
        frames.recordFrame(
          _timing(
            atMicros: base + kFrameWindowCap.inMicroseconds + 1000,
            buildMs: 4,
            rasterMs: 5,
          ),
        );
      }
    }

    // One backgrounding round trip: paused (flush + the closing bookend + the
    // reservoir drain) then resumed, inside the idle window so the session
    // survives it.
    final lifecycle = g.wiring.lifecycleHook!;
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    g.advance(const Duration(minutes: 1));
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();

    // Close the session: idle past the window, then poke it. A rotation is the
    // only path to `session.finalized` — there is no timer to fire one.
    g.advance(span + const Duration(minutes: 31));
    g.session.handleResume();
    g.wiring.pipeline.flush();
    await tester.pump();
  }

  // -------------------------------------------------------------------------
  // The budget
  // -------------------------------------------------------------------------

  testWidgets('budget: the typical reference session fits its ceilings', (
    tester,
  ) async {
    final g = await gate(tester);
    final id = g.sessionId;

    await driveReferenceSession(
      tester,
      g,
      screens: 8,
      requests: 40,
      actions: 25,
      span: const Duration(minutes: 10),
    );

    final items = g.recorder.itemsFor(id);
    expect(
      items.length,
      lessThanOrEqualTo(kTypicalItemCeiling),
      reason:
          '${items.length} items for the typical session exceeds '
          '$kTypicalItemCeiling — a new default-on signal must be traded for '
          'an existing one, not added on top',
    );
    expect(
      g.recorder.uncompressedBytes,
      lessThanOrEqualTo(kTypicalByteCeiling),
      reason:
          '${g.recorder.uncompressedBytes} uncompressed bytes exceeds '
          '$kTypicalByteCeiling',
    );
    expect(
      g.recorder.wireBytes,
      lessThanOrEqualTo(kTypicalWireCeiling),
      reason: '${g.recorder.wireBytes} wire bytes exceeds $kTypicalWireCeiling',
    );
    await tester.pump();
    g.wiring.disposeAll();
  });

  testWidgets(
    'budget: the default configuration sits at or under 40% of the typical '
    'ceiling',
    (tester) async {
      final g = await gate(tester);
      final id = g.sessionId;

      await driveReferenceSession(
        tester,
        g,
        screens: 8,
        requests: 40,
        actions: 25,
        span: const Duration(minutes: 10),
      );

      const allowance = kTypicalItemCeiling * kDefaultBudgetShare;
      final items = g.recorder.itemsFor(id);
      expect(
        items.length,
        lessThanOrEqualTo(allowance),
        reason:
            'the default allocation is ${items.length} items against an '
            'allowance of ${allowance.round()} (40% of $kTypicalItemCeiling). '
            'The remaining 60% is the pathological-session headroom the shed '
            'ceilings defend, not spare capacity for new default signals.',
      );
      // The same run is also the no-slack claim: the default is not far under.
      expect(
        items.length,
        greaterThan(allowance * 0.5),
        reason:
            'the default allocation has dropped to ${items.length} items, well '
            'under the ${allowance.round()} it was measured at. If a signal '
            'was deliberately removed, move this floor; if one stopped '
            'emitting by accident, this is the failure.',
      );
      await tester.pump();
      g.wiring.disposeAll();
    },
  );

  testWidgets('budget: the heavy reference session fits its ceilings', (
    tester,
  ) async {
    final g = await gate(tester);
    final id = g.sessionId;

    await driveReferenceSession(
      tester,
      g,
      screens: 30,
      requests: 200,
      actions: 150,
      span: const Duration(minutes: 45),
    );

    final items = g.recorder.itemsFor(id);
    expect(
      items.length,
      lessThanOrEqualTo(kHeavyItemCeiling),
      reason:
          '${items.length} items for the heavy session exceeds '
          '$kHeavyItemCeiling',
    );
    expect(
      g.recorder.uncompressedBytes,
      lessThanOrEqualTo(kHeavyByteCeiling),
      reason:
          '${g.recorder.uncompressedBytes} uncompressed bytes exceeds '
          '$kHeavyByteCeiling',
    );
    expect(
      g.recorder.wireBytes,
      lessThanOrEqualTo(kHeavyWireCeiling),
      reason: '${g.recorder.wireBytes} wire bytes exceeds $kHeavyWireCeiling',
    );
    await tester.pump();
    g.wiring.disposeAll();
  });

  // -------------------------------------------------------------------------
  // The governor
  // -------------------------------------------------------------------------

  group('budget governor', () {
    test('sheds the lowest tier first, and never essential', () {
      final shed = <String>[];
      final gate = CaptureGate(
        const TelemetryConfig(
          serviceName: 'g',
          endpoint: 'https://x.test',
          tier: CollectionTier.diagnostic,
        ),
        onShed: () => shed.add('shed'),
      );

      expect(gate.shedTier, isNull);
      expect(gate.allows(Capture.swipes), isTrue);
      expect(gate.allows(Capture.http), isTrue);

      // Cross the typical ceiling → diagnostic goes, standard stays.
      for (var i = 0; i <= kDiagnosticShedCeiling; i++) {
        gate.recordItem();
      }
      expect(gate.shedTier, CollectionTier.diagnostic);
      expect(gate.allows(Capture.swipes), isFalse);
      expect(gate.allows(Capture.http), isTrue);
      expect(shed, isNotEmpty, reason: 'every shed lands on the drop counter');

      // Cross the heavy ceiling → standard goes too.
      while (gate.itemCount <= kStandardShedCeiling) {
        gate.recordItem();
      }
      expect(gate.shedTier, CollectionTier.standard);
      expect(gate.allows(Capture.http), isFalse);
      expect(gate.allows(Capture.navigation), isFalse);

      // `essential` is unreachable by construction, which is the assertion:
      // the governor sheds by tier rank, so a shed set containing the crash and
      // the session bookends would need an `essential` member to shed. There is
      // none, and the enum is closed at that boundary on purpose.
      expect(
        Capture.values.where((c) => c.tier == CollectionTier.essential),
        isEmpty,
        reason:
            'a Capture member on the essential tier would make the crash and '
            'the session bookends sheddable — the one thing the governor must '
            'never reach',
      );
      expect(
        CollectionTier.essential.index,
        lessThan(CollectionTier.standard.index),
        reason: 'shed rank is the enum order; essential must sort below both',
      );

      gate.resetBudget();
      expect(gate.shedTier, isNull);
      expect(gate.itemCount, 0);
    });

    testWidgets(
      'a shed session still delivers its crash and its session bookends',
      (tester) async {
        final g = await gate(tester);
        final id = g.sessionId;

        // Push the governor past both ceilings through real activity, then
        // prove the essential set still lands.
        for (var i = 0; i <= kStandardShedCeiling; i++) {
          g.wiring.gate.recordItem();
        }
        expect(g.wiring.gate.shedTier, CollectionTier.standard);

        g.telemetry.trackError(StateError('after the shed'));
        g.advance(const Duration(minutes: 31));
        g.session.handleResume();
        g.wiring.pipeline.flush();
        await tester.pump();

        final names = g.recorder.itemsFor(id).map(_Recorder.nameOf).toList();
        expect(names, contains('app.crash'));
        expect(names, contains('session.started'));
        expect(names, contains('session.finalized'));
        await tester.pump();
        g.wiring.disposeAll();
      },
    );
  });

  // -------------------------------------------------------------------------
  // The native seam, extended to the device-state read (#91)
  // -------------------------------------------------------------------------

  testWidgets('native seam: the device-state read feeds both memory bookends', (
    tester,
  ) async {
    final g = await gate(tester);
    final id = g.sessionId;

    await driveReferenceSession(
      tester,
      g,
      screens: 1,
      requests: 1,
      actions: 1,
      span: const Duration(minutes: 1),
    );

    // One channel, two methods — the #91 extension. The drain is asserted from
    // the seam rather than from init order: `TelemetryWiring.build` does not
    // call it (the facade's own `initialize` does, after the wiring exists), so
    // asserting it here would be asserting the harness.
    expect(await g.wiring.nativeCrash.drainNativeCrashes(), isEmpty);
    expect(nativeCalls, contains('drainNativeCrashes'));
    expect(
      nativeCalls.where((m) => m == 'readDeviceState').length,
      greaterThanOrEqualTo(2),
      reason: 'one read per bookend: session start and paused',
    );

    final memory =
        g.recorder
            .itemsFor(id)
            .where((i) => _Recorder.nameOf(i) == 'memory_usage')
            .toList();
    expect(memory, hasLength(2), reason: 'two bookends, never a cadence');
    final phases =
        memory.map((i) => (i['attributes'] as Map)['memory.phase']).toSet();
    expect(phases, {'session_start', 'session_end'});
    for (final item in memory) {
      final attrs = item['attributes'] as Map;
      // The quantity is native and says so — v2's `rss` was the wrong number on
      // both platforms and the two were not comparable.
      expect(attrs['memory.source'], 'pss');
      expect(attrs.containsKey('memory.type'), isFalse);
    }
    await tester.pump();
    g.wiring.disposeAll();
  });

  // -------------------------------------------------------------------------
  // Release metadata and the API surface
  // -------------------------------------------------------------------------

  test('sdk.version constant matches the package manifest', () {
    final manifest = File('pubspec.yaml').readAsLinesSync();
    final declared =
        manifest
            .firstWhere((l) => l.startsWith('version:'))
            .split(':')
            .last
            .trim();
    expect(
      kSdkVersion,
      declared,
      reason:
          'a release bumps both — a backend that cannot tell which SDK build '
          'produced a row cannot tell a fixed defect from a live one',
    );
  });

  testWidgets('public-API break set: the kept v3 surface still compiles', (
    tester,
  ) async {
    // The removals are enforced by the compiler: referencing withSpan,
    // withNetworkSpan, useJsonFormat, batchTimeout, maxBatchSize,
    // eventBatchSize, enableCrashReporting or enableErrorReporting fails the
    // build, so there is nothing to assert about them here. This asserts the
    // other half of that diff — the surface that must survive — because a
    // member removed by accident is the failure a break-set list cannot catch.
    final g = await gate(tester);
    final t = g.telemetry;

    final kept = <Function>[
      // v2, kept.
      t.trackEvent,
      t.trackMetric,
      t.trackError,
      t.setUserProfile,
      t.clearUserProfile,
      t.addBreadcrumb,
      // v3 additions.
      t.trackAction,
      t.reportScreenSettled,
      t.captureClient,
      t.startTask,
      t.completeTask,
      t.failTask,
    ];
    expect(kept, hasLength(12));
    expect(t.navigationObserver, isNotNull);

    // The config surface the v3 guide tells consumers to move to.
    const config = TelemetryConfig(
      serviceName: 'g',
      endpoint: 'https://x.test',
      tier: CollectionTier.essential,
      captureOverrides: {Capture.http: false},
      traceHostAllowlist: ['.example.com'],
      batchSize: 30,
      flushIntervalMs: 5000,
    );
    expect(config.capturesEnabled(Capture.http), isFalse);
    await tester.pump();
    g.wiring.disposeAll();
  });

  testWidgets('perf: event-record stays under the 1ms Android bar', (
    tester,
  ) async {
    final g = await gate(tester);

    const n = 2000;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      g.wiring.collector.add(
        const EdgeEvent.event(
          'navigation',
          attributes: {'navigation.to': '/x'},
        ),
      );
    }
    sw.stop();

    final perEventUs = sw.elapsedMicroseconds / n;
    // The bar is three orders of magnitude above the real cost, which is why
    // runner noise cannot reach it — unlike the per-frame ceiling this file
    // declines to assert.
    expect(
      perEventUs,
      lessThan(1000),
      reason: '${perEventUs.toStringAsFixed(1)}us/event exceeds the 1ms bar',
    );
    await tester.pump();
    g.wiring.disposeAll();
  });
}

int _pointerId = 0;

/// One completed tap through the real global pointer route — the same path a
/// user's finger takes, so `ui.interaction` is built by the hook rather than
/// handed to the Collector.
void _tap(int i, {Duration at = Duration.zero}) {
  final router = GestureBinding.instance.pointerRouter;
  final pointer = ++_pointerId;
  final origin = Offset(100 + (i % 20), 200 + (i % 20));
  router.route(
    PointerDownEvent(
      pointer: pointer,
      position: origin,
      timeStamp: at,
      kind: PointerDeviceKind.touch,
    ),
  );
  router.route(
    PointerUpEvent(
      pointer: pointer,
      position: origin,
      timeStamp: at + const Duration(milliseconds: 60),
      kind: PointerDeviceKind.touch,
    ),
  );
}

FrameTiming _timing({
  required int atMicros,
  required int buildMs,
  required int rasterMs,
}) {
  int us(num ms) => (ms * 1000).round();
  final vsyncStart = atMicros - us(buildMs + rasterMs);
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: vsyncStart + us(1),
    buildFinish: vsyncStart + us(1 + buildMs),
    rasterStart: atMicros - us(rasterMs),
    rasterFinish: atMicros,
    rasterFinishWallTime: atMicros,
  );
}
