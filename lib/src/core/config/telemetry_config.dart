// lib/src/core/config/telemetry_config.dart - Enhanced with HTTP monitoring

/// Configuration class for EdgeTelemetry initialization
///
/// Contains all settings needed to set up automatic telemetry collection and reporting
class TelemetryConfig {
  /// Name of the service/app for telemetry identification
  final String serviceName;

  /// Backend endpoint URL for sending telemetry data
  final String endpoint;

  /// Enable debug logging and console output
  final bool debugMode;

  /// Global attributes added to all spans and events
  final Map<String, String> globalAttributes;

  /// Batch timeout for sending telemetry data
  final Duration batchTimeout;

  /// Maximum number of spans in a batch
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

  /// Number of events to batch before sending
  final int eventBatchSize;

  const TelemetryConfig({
    required this.serviceName,
    required this.endpoint,
    this.debugMode = false,
    this.globalAttributes = const {},
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
    bool? debugMode,
    Map<String, String>? globalAttributes,
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
      debugMode: debugMode ?? this.debugMode,
      globalAttributes: globalAttributes ?? this.globalAttributes,
      batchTimeout: batchTimeout ?? this.batchTimeout,
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
  Batch: $eventBatchSize events / ${batchTimeout.inSeconds}s
  Local Reports: $enableLocalReporting
''';
  }
}
