// lib/src/facade/telemetry_wiring.dart

import '../capture/action_capture_hook.dart';
import '../capture/capture_hook.dart';
import '../capture/http_capture_hook.dart';
import '../capture/lifecycle_capture_hook.dart';
import '../capture/nav_capture_hook.dart';
import '../capture/network_capture_hook.dart';
import '../capture/perf_capture_hook.dart';
import '../capture/screen_load_hook.dart';
import '../capture/trace_injection.dart';
import '../core/attribute_policy.dart';
import '../core/capture_gate.dart';
import '../core/collector.dart';
import '../core/offline_queue.dart';
import '../core/pipeline.dart';
import '../core/retry_transport.dart';
import '../core/config/collection_tier.dart';
import '../core/config/telemetry_config.dart';
import '../crash/crash_reporting.dart';
import '../crash/native_crash_channel.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/context_manager.dart';
import '../managers/session_manager.dart';
import '../managers/trace_manager.dart';
import '../widgets/edge_navigation_observer.dart';

/// The one construction site. Builds the graph bottom-up
/// (`OfflineQueue → RetryTransport → Pipeline → Collector`), injects the
/// managers, starts the capture hooks, and holds every dispose handle.
///
/// Injected into the facade via `EdgeTelemetry.fromWiring` — the single
/// injection point that makes the whole stack fakeable in tests.
class TelemetryWiring {
  final TelemetryConfig config;
  final SessionManager session;
  final ContextManager context;

  /// Held here rather than reached through [context]: the wiring is what
  /// hands it to the hooks that mint roots, and `ContextManager` holds it only
  /// to merge its ambient keys.
  final TraceManager trace;
  final BreadcrumbManager breadcrumbs;
  final CrashReporting crashReporting;
  final NativeCrashChannel nativeCrash;
  final OfflineQueue queue;
  final RetryTransport transport;
  final Pipeline pipeline;
  final Collector collector;

  /// The tier gate every capture hook is started behind. Hooks that need
  /// emit-level gating (a variant or field off inside a running hook) hold it
  /// too; the check goes *before* the attribute-map literal, never after.
  final CaptureGate gate;

  /// The PII policy the Collector applies to every item's own attributes.
  final AttributePolicy policy;

  final List<DisposeHandle> _disposers;

  /// Held so the facade's one `captureClient` call has somewhere to go. Null
  /// when `Capture.http` is off — which is exactly the disabled-capture case
  /// that must return the consumer's client unchanged.
  final HttpCaptureHook? httpHook;
  final NavCaptureHook? navHook;
  final NetworkCaptureHook? networkHook;

  /// Held so the facade's `reportScreenSettled()` has somewhere to go. Null
  /// when `Capture.screenLoad` is off — the call is then a no-op, which is the
  /// consumer's own choice rather than a silent failure.
  final ScreenLoadHook? screenLoadHook;

  TelemetryWiring({
    required this.config,
    required this.session,
    required this.context,
    required this.trace,
    required this.breadcrumbs,
    required this.crashReporting,
    required this.queue,
    required this.transport,
    required this.pipeline,
    required this.collector,
    required List<DisposeHandle> disposers,
    CaptureGate? gate,
    AttributePolicy? policy,
    NativeCrashChannel? nativeCrash,
    this.httpHook,
    this.navHook,
    this.networkHook,
    this.screenLoadHook,
  })  : _disposers = disposers,
        gate = gate ?? CaptureGate(config),
        policy = policy ?? AttributePolicy(redact: config.redactAttribute),
        nativeCrash = nativeCrash ?? NativeCrashChannel();

  EdgeNavigationObserver? get navigationObserver => navHook?.observer;

  /// Build and start the full stack from an initialized set of managers.
  static Future<TelemetryWiring> build({
    required TelemetryConfig config,
    required SessionManager session,
    required ContextManager context,
    required TraceManager trace,
    required BreadcrumbManager breadcrumbs,
  }) async {
    // Resolve the collection surface once: overrides → deprecated booleans →
    // tier default. Every shed the governor makes lands on the session's
    // dropped-item counter, the same counter the off-canon drop uses.
    final gate =
        CaptureGate(config, onShed: () => session.recordDropped('tier_shed'));

    // The PII policy: the consumer's one redaction hook plus the per-key
    // cardinality cap, both per session and both applied at the Collector.
    final policy = AttributePolicy(
      redact: config.redactAttribute,
      onCapped: session.recordCardinalityCap,
    );

    // Every delivery-side give-up lands on the same session counter as the
    // off-canon drop and the tier shed: a payload the SDK declined to send.
    final queue = OfflineQueue(
      debugMode: config.debugMode,
      maxQueueSize: config.maxQueueSize,
      onDrop: session.recordDropped,
    );
    await queue.initialize();

    final transport = RetryTransport(
      endpoint: config.endpoint,
      apiKey: config.apiKey,
      queue: queue,
      debugMode: config.debugMode,
      onDrop: session.recordDropped,
    );
    // Drain any crashes persisted on a previous launch (drain-on-startup).
    await transport.drainQueue();

    final pipeline = Pipeline(
      transport: transport,
      batchSize: config.batchSize,
      flushInterval: Duration(milliseconds: config.flushIntervalMs),
      debugMode: config.debugMode,
    );

    final collector = Collector(
      context: context,
      session: session,
      pipeline: pipeline,
      breadcrumbs: breadcrumbs,
      debugMode: config.debugMode,
      gate: gate,
      policy: policy,
    );

    // Both per-session ceilings start a fresh allowance on rotation: the
    // governor's item budget and the Collector's `ui.interaction` cap.
    session.onSessionStart = () {
      gate.resetBudget();
      collector.resetActionCap();
      policy.reset();
    };

    // Late-bind the session bookend sink now the Collector exists (breaks the
    // session↔collector construction cycle). session.started/finalized route
    // here from now on.
    session.bindSink(collector);

    const crashReporting = CrashReporting();

    final disposers = <DisposeHandle>[];
    NavCaptureHook? navHook;
    NetworkCaptureHook? networkHook;

    if (gate.allows(Capture.connectivity)) {
      networkHook = NetworkCaptureHook(context: context);
      disposers.add(networkHook.start(collector));
    }
    // ponytail: one hook serves both captures, so either alone keeps it
    // running. Split PerfCaptureHook when frames and health need separate
    // switches — the ticket that splits the emitters owns that.
    if (gate.allows(Capture.frames) || gate.allows(Capture.health)) {
      disposers.add(PerfCaptureHook().start(collector));
    }
    HttpCaptureHook? httpHook;
    if (gate.allows(Capture.http)) {
      httpHook = HttpCaptureHook(
        debugMode: config.debugMode,
        breadcrumbs: breadcrumbs,
        gate: gate,
        injector: TraceInjector(
          trace: trace,
          allowlist: config.traceHostAllowlist,
          debugMode: config.debugMode,
        ),
        // Explicit self-exclusion. The construction ordering above (transport
        // built before the hook installs the override) is kept as well — belt
        // and braces, because the failure mode is unbounded amplification.
        selfUrl: transport.resolvedUrl,
      );
      disposers.add(httpHook.start(collector));
    }
    // Built before the nav hook that drives it, and started before it too:
    // the very first route push must find a hook with a sink already bound.
    //
    // `Capture.navigation` is in the condition because a screen entry is a
    // navigation: with the observer off there is nothing to time, and a hook
    // that started, bound the in-flight listener and then emitted nothing
    // would be indistinguishable from an app whose screens never load.
    ScreenLoadHook? screenLoadHook;
    if (gate.allows(Capture.screenLoad) && gate.allows(Capture.navigation)) {
      screenLoadHook = ScreenLoadHook(session: session, trace: trace);
      disposers.add(screenLoadHook.start(collector));
    }
    if (gate.allows(Capture.navigation)) {
      navHook = NavCaptureHook(
        session: session,
        breadcrumbs: breadcrumbs,
        trace: trace,
        screenLoad: screenLoadHook,
      );
      disposers.add(navHook.start(collector));
    }
    if (gate.allows(Capture.actions)) {
      disposers.add(ActionCaptureHook(
        trace: trace,
        session: session,
        breadcrumbs: breadcrumbs,
        gate: gate,
      ).start(collector));
    }

    // The lifecycle→session bridge (paused=flush+mark, resume=rotate-if-idle)
    // is always on — it drives the session model, not an optional monitor. The
    // `app_lifecycle` *event* it also emits is tiered, so the hook holds the
    // gate and checks per emission rather than being started behind one.
    disposers.add(
      LifecycleCaptureHook(
        session: session,
        trace: trace,
        flush: pipeline.flush,
        onPaused: screenLoadHook?.onPaused,
        breadcrumbs: breadcrumbs,
        gate: gate,
      ).start(collector),
    );

    return TelemetryWiring(
      config: config,
      session: session,
      context: context,
      trace: trace,
      breadcrumbs: breadcrumbs,
      crashReporting: crashReporting,
      queue: queue,
      transport: transport,
      pipeline: pipeline,
      collector: collector,
      disposers: disposers,
      gate: gate,
      policy: policy,
      httpHook: httpHook,
      navHook: navHook,
      networkHook: networkHook,
      screenLoadHook: screenLoadHook,
    );
  }

  /// Dispose every capture hook and free the transport/pipeline.
  void disposeAll() {
    for (final dispose in _disposers) {
      dispose();
    }
    pipeline.dispose();
    transport.dispose();
  }
}
