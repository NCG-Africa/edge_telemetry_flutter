// lib/src/core/config/telemetry_config.dart

import 'collection_tier.dart';

/// Configuration for `EdgeTelemetry.initialize()`.
///
/// The v3 collection surface is **two fields** — [tier] and [captureOverrides].
/// The v2 capture booleans survive deprecated-in-place and act as a fallback;
/// the new key always wins.
class TelemetryConfig {
  /// Name of the service/app for telemetry identification
  final String serviceName;

  /// Base backend URL. The SDK POSTs to `<endpoint>/collector/telemetry`.
  final String endpoint;

  /// API key sent as the `X-API-Key` header. Null = header omitted (the
  /// Collector 401s without it in api_key mode — dev/self-hosted only).
  final String? apiKey;

  /// Fraction of sessions kept (0.0–1.0). Rolled once per session (#25): a
  /// sampled-out session drops its subject-to-sample events coherently, while
  /// crashes, `session.*` bookends, and `user.profile.update` still land. 1.0
  /// (default) = no roll, keep everything.
  ///
  /// Orthogonal to [tier]: sampling says how often, tiers say what at all.
  final double sampleRate;

  /// Enable debug logging and console output
  final bool debugMode;

  /// Global attributes added to all spans and events
  final Map<String, String> globalAttributes;

  /// Number of events per batch before a send (canon name).
  final int batchSize;

  /// Idle time before a partial batch is sent, in ms (canon name; default 5s).
  final int flushIntervalMs;

  /// Max batches held in the offline queue before drop-oldest kicks in.
  /// Crashes (`crash_` prefix) are exempt and never dropped.
  final int maxQueueSize;

  /// The dial. `standard` (default) collects the default-on set; `essential`
  /// sheds everything sheddable and is the real answer to "send me almost
  /// nothing"; `diagnostic` turns the opt-in set on as well.
  final CollectionTier tier;

  /// The scalpel, in both directions: `{Capture.swipes: true}` adds a
  /// diagnostic capture to a standard config, `{Capture.http: false}` removes a
  /// standard one. Wins over [tier] **and** over the deprecated booleans below.
  final Map<Capture, bool> captureOverrides;

  /// The one redaction hook, run at the single wire choke point over an
  /// item's **own** attributes — never the ~30-key context snapshot, which
  /// would be 30 consumer callbacks per item on the UI isolate for values the
  /// SDK chose itself.
  ///
  /// Return the value to send, or null to drop the key entirely. PII
  /// partitions by who chose the value: the SDK redacts what it collected
  /// (URLs), caps what the developer named (cardinality), and hands the
  /// developer this hook over what they supplied.
  final String? Function(String key, String value)? redactAttribute;

  /// Hosts a W3C `traceparent` may be injected into, so a mobile tap and a
  /// backend span sit in one trace.
  ///
  /// Matching is the family's rule verbatim: **exact host, or a dot-anchored
  /// suffix of at least two labels** — `.example.com` matches `api.example.com`
  /// and never `api.example.com.evil.com`.
  ///
  /// **Empty (the default) means dark: no header is injected anywhere.** The
  /// header carries internal trace topology, so listing a host is a decision to
  /// disclose it — not a default anyone should inherit. Requests to unlisted
  /// hosts are still captured and still carry local trace ids; only the header
  /// is withheld.
  final List<String> traceHostAllowlist;

  /// Enable automatic network monitoring (connectivity changes)
  @Deprecated('Use captureOverrides[Capture.connectivity]. Removed in v4.0.0.')
  final bool enableNetworkMonitoring;

  /// Enable automatic performance monitoring (frame drops, memory)
  @Deprecated(
      'Use captureOverrides[Capture.frames] / [Capture.health]. Removed in v4.0.0.')
  final bool enablePerformanceMonitoring;

  /// Enable automatic navigation tracking
  @Deprecated('Use captureOverrides[Capture.navigation]. Removed in v4.0.0.')
  final bool enableNavigationTracking;

  /// Enable automatic HTTP request monitoring.
  /// This intercepts ALL HTTP requests made by the app.
  @Deprecated('Use captureOverrides[Capture.http]. Removed in v4.0.0.')
  final bool enableHttpMonitoring;

  /// Capture the accessibility-sensitive device keys (`device.text_scale_factor`,
  /// `device.reduce_motion`). `device.platform_brightness` is captured
  /// regardless — it carries no flag.
  @Deprecated(
      'Use captureOverrides[Capture.accessibilityContext]. Removed in v4.0.0.')
  final bool captureAccessibilityContext;

  // Report system configuration
  /// Enable local data storage for generating reports.
  ///
  /// **Not** a capture and deliberately not deprecated: it gates a *sink* (the
  /// on-device report store behind `generateSummaryReport` and friends), never
  /// a hook, and never touches the wire.
  final bool enableLocalReporting;

  /// Path for local report storage (null = use default)
  final String? reportStoragePath;

  /// How long to keep data for reports (default: 30 days)
  final Duration dataRetentionPeriod;

  const TelemetryConfig({
    required this.serviceName,
    required this.endpoint,
    this.apiKey,
    this.sampleRate = 1.0,
    this.debugMode = false,
    this.globalAttributes = const {},
    this.batchSize = 30,
    this.flushIntervalMs = 5000,
    this.maxQueueSize = 200,
    this.tier = CollectionTier.standard,
    this.captureOverrides = const {},
    this.redactAttribute,
    this.traceHostAllowlist = const [],
    @Deprecated(
        'Use captureOverrides[Capture.connectivity]. Removed in v4.0.0.')
    this.enableNetworkMonitoring = true,
    @Deprecated(
        'Use captureOverrides[Capture.frames] / [Capture.health]. Removed in v4.0.0.')
    this.enablePerformanceMonitoring = true,
    @Deprecated('Use captureOverrides[Capture.navigation]. Removed in v4.0.0.')
    this.enableNavigationTracking = true,
    @Deprecated('Use captureOverrides[Capture.http]. Removed in v4.0.0.')
    this.enableHttpMonitoring = true,
    @Deprecated(
        'Use captureOverrides[Capture.accessibilityContext]. Removed in v4.0.0.')
    this.captureAccessibilityContext = false,
    this.enableLocalReporting = false,
    this.reportStoragePath,
    this.dataRetentionPeriod = const Duration(days: 30),
  });

  /// Create a copy of this config with some values overridden
  TelemetryConfig copyWith({
    String? serviceName,
    String? endpoint,
    String? apiKey,
    double? sampleRate,
    bool? debugMode,
    Map<String, String>? globalAttributes,
    int? batchSize,
    int? flushIntervalMs,
    int? maxQueueSize,
    CollectionTier? tier,
    Map<Capture, bool>? captureOverrides,
    String? Function(String key, String value)? redactAttribute,
    List<String>? traceHostAllowlist,
    @Deprecated(
        'Use captureOverrides[Capture.connectivity]. Removed in v4.0.0.')
    bool? enableNetworkMonitoring,
    @Deprecated(
        'Use captureOverrides[Capture.frames] / [Capture.health]. Removed in v4.0.0.')
    bool? enablePerformanceMonitoring,
    @Deprecated('Use captureOverrides[Capture.navigation]. Removed in v4.0.0.')
    bool? enableNavigationTracking,
    @Deprecated('Use captureOverrides[Capture.http]. Removed in v4.0.0.')
    bool? enableHttpMonitoring,
    @Deprecated(
        'Use captureOverrides[Capture.accessibilityContext]. Removed in v4.0.0.')
    bool? captureAccessibilityContext,
    bool? enableLocalReporting,
    String? reportStoragePath,
    Duration? dataRetentionPeriod,
  }) {
    return TelemetryConfig(
      serviceName: serviceName ?? this.serviceName,
      endpoint: endpoint ?? this.endpoint,
      apiKey: apiKey ?? this.apiKey,
      sampleRate: sampleRate ?? this.sampleRate,
      debugMode: debugMode ?? this.debugMode,
      globalAttributes: globalAttributes ?? this.globalAttributes,
      batchSize: batchSize ?? this.batchSize,
      flushIntervalMs: flushIntervalMs ?? this.flushIntervalMs,
      maxQueueSize: maxQueueSize ?? this.maxQueueSize,
      tier: tier ?? this.tier,
      captureOverrides: captureOverrides ?? this.captureOverrides,
      redactAttribute: redactAttribute ?? this.redactAttribute,
      traceHostAllowlist: traceHostAllowlist ?? this.traceHostAllowlist,
      // ignore: deprecated_member_use_from_same_package
      enableNetworkMonitoring:
          // ignore: deprecated_member_use_from_same_package
          enableNetworkMonitoring ?? this.enableNetworkMonitoring,
      // ignore: deprecated_member_use_from_same_package
      enablePerformanceMonitoring:
          // ignore: deprecated_member_use_from_same_package
          enablePerformanceMonitoring ?? this.enablePerformanceMonitoring,
      // ignore: deprecated_member_use_from_same_package
      enableNavigationTracking:
          // ignore: deprecated_member_use_from_same_package
          enableNavigationTracking ?? this.enableNavigationTracking,
      // ignore: deprecated_member_use_from_same_package
      enableHttpMonitoring:
          // ignore: deprecated_member_use_from_same_package
          enableHttpMonitoring ?? this.enableHttpMonitoring,
      // ignore: deprecated_member_use_from_same_package
      captureAccessibilityContext:
          // ignore: deprecated_member_use_from_same_package
          captureAccessibilityContext ?? this.captureAccessibilityContext,
      enableLocalReporting: enableLocalReporting ?? this.enableLocalReporting,
      reportStoragePath: reportStoragePath ?? this.reportStoragePath,
      dataRetentionPeriod: dataRetentionPeriod ?? this.dataRetentionPeriod,
    );
  }

  /// Whether [c] is enabled by this configuration: the override map wins, then
  /// the deprecated booleans, then the [tier] default. Runtime shedding is the
  /// governor's, on `CaptureGate` — this is the config half only.
  bool capturesEnabled(Capture c) =>
      _legacyOverrides[c] ?? c.tier.index <= tier.index;

  /// The deprecated booleans folded into override shape, with
  /// [captureOverrides] layered on top so the new key wins. A legacy `true`
  /// contributes nothing — it only ever agreed with the tier default; the
  /// exception is `captureAccessibilityContext`, whose `true` is the opt-in it
  /// always was.
  Map<Capture, bool> get _legacyOverrides => {
        // ignore: deprecated_member_use_from_same_package
        if (!enableHttpMonitoring) Capture.http: false,
        // ignore: deprecated_member_use_from_same_package
        if (!enableNavigationTracking) Capture.navigation: false,
        // ignore: deprecated_member_use_from_same_package
        if (!enablePerformanceMonitoring) ...{
          Capture.frames: false,
          Capture.health: false,
        },
        // ignore: deprecated_member_use_from_same_package
        if (!enableNetworkMonitoring) Capture.connectivity: false,
        // ignore: deprecated_member_use_from_same_package
        if (captureAccessibilityContext) Capture.accessibilityContext: true,
        ...captureOverrides,
      };

  /// Every capture this config enables, by name — for debug output.
  Map<String, bool> get enabledFeatures => {
        for (final c in Capture.values) c.name: capturesEnabled(c),
        'localReporting': enableLocalReporting,
      };

  /// Whether any automatic capture is running.
  bool get hasAutomaticMonitoring => Capture.values.any(capturesEnabled);

  /// Get configuration summary for debugging
  String get summary {
    final on = Capture.values.where(capturesEnabled).map((c) => c.name);
    return '''
EdgeTelemetry Configuration:
  Service: $serviceName
  Endpoint: $endpoint
  Debug: $debugMode
  Tier: ${tier.name}
  Captures: ${on.join(', ')}
  Batch: $batchSize events / ${flushIntervalMs}ms
  Local Reports: $enableLocalReporting
''';
  }
}
