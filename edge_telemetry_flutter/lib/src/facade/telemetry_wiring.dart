// lib/src/facade/telemetry_wiring.dart

import '../capture/capture_hook.dart';
import '../capture/http_capture_hook.dart';
import '../capture/nav_capture_hook.dart';
import '../capture/network_capture_hook.dart';
import '../capture/perf_capture_hook.dart';
import '../core/collector.dart';
import '../core/offline_queue.dart';
import '../core/pipeline.dart';
import '../core/retry_transport.dart';
import '../core/config/telemetry_config.dart';
import '../crash/crash_reporting.dart';
import '../crash/native_crash_channel.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/context_manager.dart';
import '../managers/session_manager.dart';
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
  final BreadcrumbManager breadcrumbs;
  final CrashReporting crashReporting;
  final NativeCrashChannel nativeCrash;
  final OfflineQueue queue;
  final RetryTransport transport;
  final Pipeline pipeline;
  final Collector collector;

  final List<DisposeHandle> _disposers;
  final NavCaptureHook? navHook;
  final NetworkCaptureHook? networkHook;

  TelemetryWiring({
    required this.config,
    required this.session,
    required this.context,
    required this.breadcrumbs,
    required this.crashReporting,
    required this.queue,
    required this.transport,
    required this.pipeline,
    required this.collector,
    required List<DisposeHandle> disposers,
    NativeCrashChannel? nativeCrash,
    this.navHook,
    this.networkHook,
  })  : _disposers = disposers,
        nativeCrash = nativeCrash ?? NativeCrashChannel();

  EdgeNavigationObserver? get navigationObserver => navHook?.observer;

  /// Build and start the full stack from an initialized set of managers.
  static Future<TelemetryWiring> build({
    required TelemetryConfig config,
    required SessionManager session,
    required ContextManager context,
    required BreadcrumbManager breadcrumbs,
  }) async {
    final queue = OfflineQueue(debugMode: config.debugMode);
    await queue.initialize();

    final transport = RetryTransport(
      endpoint: config.endpoint,
      apiKey: config.apiKey,
      queue: queue,
      debugMode: config.debugMode,
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
    );

    const crashReporting = CrashReporting();

    final disposers = <DisposeHandle>[];
    NavCaptureHook? navHook;
    NetworkCaptureHook? networkHook;

    if (config.enableNetworkMonitoring) {
      networkHook = NetworkCaptureHook(context: context);
      disposers.add(networkHook.start(collector));
    }
    if (config.enablePerformanceMonitoring) {
      disposers.add(PerfCaptureHook().start(collector));
    }
    if (config.enableHttpMonitoring) {
      disposers
          .add(HttpCaptureHook(debugMode: config.debugMode).start(collector));
    }
    if (config.enableNavigationTracking) {
      navHook = NavCaptureHook(session: session, breadcrumbs: breadcrumbs);
      disposers.add(navHook.start(collector));
    }

    return TelemetryWiring(
      config: config,
      session: session,
      context: context,
      breadcrumbs: breadcrumbs,
      crashReporting: crashReporting,
      queue: queue,
      transport: transport,
      pipeline: pipeline,
      collector: collector,
      disposers: disposers,
      navHook: navHook,
      networkHook: networkHook,
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
