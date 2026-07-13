// lib/src/core/config/telemetry_config.dart - Enhanced with HTTP monitoring

/// Configuration class for EdgeTelemetry initialization
///
/// Contains all settings needed to set up automatic telemetry collection and reporting
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

  /// Batch timeout for sending telemetry data.
  @Deprecated('Use flushIntervalMs. Removed in v3.0.0.')
  final Duration batchTimeout;

  /// Maximum number of spans in a batch (OTel-era, unused).
  @Deprecated('Use batchSize. Removed in v3.0.0.')
  final int maxBatchSize;

  /// Enable automatic network monitoring (connectivity changes)
  final bool enableNetworkMonitoring;

  /// Enable automatic performance monitoring (frame drops, memory)
  final bool enablePerformanceMonitoring;

  /// Enable automatic error and crash reporting
  final bool enableErrorReporting;

  /// Enable automatic navigation tracking
  final bool enableNavigationTracking;

  /// Enable automatic HTTP request monitoring
  /// This intercepts ALL HTTP requests made by the app
  final bool enableHttpMonitoring;

  /// Enable automatic crash reporting
  final bool enableCrashReporting;

  // Report system configuration
  /// Enable local data storage for generating reports
  final bool enableLocalReporting;

  /// Path for local report storage (null = use default)
  final String? reportStoragePath;

  /// How long to keep data for reports (default: 30 days)
  final Duration dataRetentionPeriod;

  /// Use JSON format instead of OpenTelemetry (simpler for most use cases)
  final bool useJsonFormat;

  /// Number of events to batch before sending.
  @Deprecated('Use batchSize. Removed in v3.0.0.')
  final int eventBatchSize;

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
    this.batchTimeout = const Duration(seconds: 5),
    this.maxBatchSize = 512,
    this.enableNetworkMonitoring = true,
    this.enablePerformanceMonitoring = true,
    this.enableErrorReporting = true,
    this.enableNavigationTracking = true,
    this.enableHttpMonitoring = true,
    this.enableCrashReporting = true,
    this.enableLocalReporting = false,
    this.reportStoragePath,
    this.dataRetentionPeriod = const Duration(days: 30),
    this.useJsonFormat = true,
    this.eventBatchSize = 30,
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
    Duration? batchTimeout,
    int? maxBatchSize,
    bool? enableNetworkMonitoring,
    bool? enablePerformanceMonitoring,
    bool? enableErrorReporting,
    bool? enableNavigationTracking,
    bool? enableHttpMonitoring,
    bool? enableCrashReporting,
    bool? enableLocalReporting,
    String? reportStoragePath,
    Duration? dataRetentionPeriod,
    bool? useJsonFormat,
    int? eventBatchSize,
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
      // ignore: deprecated_member_use_from_same_package
      batchTimeout: batchTimeout ?? this.batchTimeout,
      // ignore: deprecated_member_use_from_same_package
      maxBatchSize: maxBatchSize ?? this.maxBatchSize,
      enableNetworkMonitoring:
          enableNetworkMonitoring ?? this.enableNetworkMonitoring,
      enablePerformanceMonitoring:
          enablePerformanceMonitoring ?? this.enablePerformanceMonitoring,
      enableErrorReporting: enableErrorReporting ?? this.enableErrorReporting,
      enableNavigationTracking:
          enableNavigationTracking ?? this.enableNavigationTracking,
      enableHttpMonitoring: enableHttpMonitoring ?? this.enableHttpMonitoring,
      enableCrashReporting: enableCrashReporting ?? this.enableCrashReporting,
      enableLocalReporting: enableLocalReporting ?? this.enableLocalReporting,
      reportStoragePath: reportStoragePath ?? this.reportStoragePath,
      dataRetentionPeriod: dataRetentionPeriod ?? this.dataRetentionPeriod,
      useJsonFormat: useJsonFormat ?? this.useJsonFormat,
      // ignore: deprecated_member_use_from_same_package
      eventBatchSize: eventBatchSize ?? this.eventBatchSize,
    );
  }

  /// Get a summary of enabled features
  Map<String, bool> get enabledFeatures {
    return {
      'networkMonitoring': enableNetworkMonitoring,
      'performanceMonitoring': enablePerformanceMonitoring,
      'errorReporting': enableErrorReporting,
      'navigationTracking': enableNavigationTracking,
      'httpMonitoring': enableHttpMonitoring,
      'localReporting': enableLocalReporting,
    };
  }

  /// Check if any automatic monitoring is enabled
  bool get hasAutomaticMonitoring {
    return enableNetworkMonitoring ||
        enablePerformanceMonitoring ||
        enableErrorReporting ||
        enableNavigationTracking ||
        enableHttpMonitoring;
  }

  /// Get configuration summary for debugging
  String get summary {
    return '''
EdgeTelemetry Configuration:
  Service: $serviceName
  Endpoint: $endpoint
  Format: ${useJsonFormat ? 'JSON' : 'OpenTelemetry'}
  Debug: $debugMode
  Features: ${enabledFeatures.entries.where((e) => e.value).map((e) => e.key).join(', ')}
  Batch: $batchSize events / ${flushIntervalMs}ms
  Local Reports: $enableLocalReporting
''';
  }
}
