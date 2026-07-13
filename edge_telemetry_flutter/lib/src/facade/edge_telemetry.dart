// lib/src/facade/edge_telemetry.dart
//
// The thin singleton facade. Every public member is delegation only; the graph
// lives behind a private [TelemetryWiring]. This is the file consumers reach
// through the exports-only barrel (package:edge_telemetry_flutter/edge_telemetry_flutter.dart).

import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../collectors/flutter_device_info_collector.dart';
import '../core/config/telemetry_config.dart';
import '../core/edge_event.dart';
import '../core/interfaces/device_info_collector.dart';
import '../core/interfaces/report_generator.dart';
import '../core/interfaces/report_storage.dart';
import '../core/models/breadcrumb.dart';
import '../core/models/generated_report.dart';
import '../core/models/report_data.dart';
import '../core/models/telemetry_session.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/context_manager.dart';
import '../managers/identity_format.dart';
import '../managers/session_manager.dart';
import '../managers/user_id_manager.dart';
import '../reports/simple_report_generator.dart';
import '../storage/memory_report_storage.dart';
import '../widgets/edge_navigation_observer.dart';
import 'telemetry_wiring.dart';

/// Automatic Real User Monitoring for Flutter — one-call setup.
///
/// Singleton facade over the 5-layer core (`Collector → Pipeline →
/// RetryTransport → OfflineQueue`) plus the managers. All members delegate.
class EdgeTelemetry {
  static EdgeTelemetry? _instance;
  static EdgeTelemetry get instance => _instance ??= EdgeTelemetry._();

  EdgeTelemetry._();

  /// Inject a fully-built (usually faked) stack. The single test injection
  /// point — lets a test drive the facade without real initialization.
  @visibleForTesting
  EdgeTelemetry.fromWiring(TelemetryWiring wiring) {
    _wiring = wiring;
    _config = wiring.config;
    _sessionManager = wiring.session;
    _initialized = true;
  }

  // The DI'd graph.
  TelemetryWiring? _wiring;

  // Deprecated-symbol warnings, emitted once per process (debug-gated).
  static final Set<String> _deprecationWarned = {};

  // Identity + session.
  UserIdManager? _userIdManager;
  SessionManager? _sessionManager;
  String? _currentUserId;

  // User profile data (separate from ID).
  final Map<String, String> _userProfile = {};
  int _profileVersion = 0;
  static const String _profileVersionKey = 'edge_telemetry_profile_version';

  // Device info.
  DeviceInfoCollector? _deviceInfoCollector;
  Map<String, String> _globalAttributes = {};

  // Report system.
  ReportStorage? _reportStorage;
  ReportGenerator? _reportGenerator;
  TelemetrySession? _currentSession;
  String? _currentSessionId;

  bool _initialized = false;
  TelemetryConfig? _config;

  // Kept so the isolate error-listener can be detached on dispose/hot-restart.
  RawReceivePort? _isolateErrorPort;

  // ==================== INITIALIZATION ====================

  /// Initialize EdgeTelemetry with automatic monitoring capabilities.
  static Future<void> initialize({
    required String endpoint,
    required String serviceName,
    String? apiKey,
    double sampleRate = 1.0,
    bool debugMode = false,
    Map<String, String>? globalAttributes,
    int? batchSize,
    int? flushIntervalMs,
    @Deprecated('Use flushIntervalMs. Removed in v3.0.0.')
    Duration? batchTimeout,
    @Deprecated('Ignored (OTel-era). Removed in v3.0.0.') int? maxBatchSize,
    bool enableNetworkMonitoring = true,
    bool enablePerformanceMonitoring = true,
    bool enableNavigationTracking = true,
    bool enableHttpMonitoring = true,
    bool enableCrashReporting = true,
    bool enableLocalReporting = false,
    String? reportStoragePath,
    Duration? dataRetentionPeriod,
    @Deprecated(
        'useJsonFormat is ignored; the SDK is custom-JSON only. Remove the argument. Removed in v3.0.0.')
    bool useJsonFormat = true,
    @Deprecated('Use batchSize. Removed in v3.0.0.') int? eventBatchSize,
  }) async {
    // New canon keys win; deprecated keys are the fallback (backward-compat).
    final resolvedBatchSize = batchSize ?? eventBatchSize ?? 30;
    final resolvedFlushMs =
        flushIntervalMs ?? batchTimeout?.inMilliseconds ?? 5000;

    final config = TelemetryConfig(
      endpoint: endpoint,
      serviceName: serviceName,
      apiKey: apiKey,
      sampleRate: sampleRate,
      debugMode: debugMode,
      globalAttributes: globalAttributes ?? {},
      batchSize: resolvedBatchSize,
      flushIntervalMs: resolvedFlushMs,
      enableNetworkMonitoring: enableNetworkMonitoring,
      enablePerformanceMonitoring: enablePerformanceMonitoring,
      enableNavigationTracking: enableNavigationTracking,
      enableErrorReporting: true,
      enableLocalReporting: enableLocalReporting,
      reportStoragePath: reportStoragePath,
      dataRetentionPeriod: dataRetentionPeriod ?? const Duration(days: 30),
      useJsonFormat: true, // custom-JSON is the only backend now
      // ignore: deprecated_member_use_from_same_package
      eventBatchSize: resolvedBatchSize,
      enableHttpMonitoring: enableHttpMonitoring,
      enableCrashReporting: enableCrashReporting,
    );

    await instance._setup(config);

    // ignore: deprecated_member_use_from_same_package
    if (!useJsonFormat) {
      instance._warnDeprecatedOnce('useJsonFormat',
          'useJsonFormat is ignored; the SDK is custom-JSON only. Remove the argument. Removed in v3.0.0.');
    }
  }

  void _warnDeprecatedOnce(String key, String message) {
    if (_config?.debugMode != true) return;
    if (_deprecationWarned.add(key)) {
      print('⚠️ DEPRECATED: $message');
    }
  }

  Future<void> _setup(TelemetryConfig config) async {
    if (_initialized) return;
    _config = config;

    try {
      // Identity + session.
      _userIdManager = UserIdManager();
      _currentUserId = await _userIdManager!.getUserId();

      // Timer-free lazy session model. The session is started *after* the
      // wiring is built (below) so `recoverAndStart` can emit session.started
      // (and any backdated kill-recovery finalize) through the Collector.
      // Per-session sampling roll only when sampling is on (rate < 1.0). At 1.0
      // there's no roll → no `session.sampled` on the wire (byte-identical).
      _sessionManager = SessionManager(
        newSessionId: _generateSessionId,
        sampledRoll: config.sampleRate >= 1.0
            ? null
            : () => Random().nextDouble() < config.sampleRate,
      );

      await _loadProfileVersion();

      // Device + app info → global context bag.
      _deviceInfoCollector = FlutterDeviceInfoCollector();
      _globalAttributes = await _deviceInfoCollector!.collectDeviceInfo();
      _globalAttributes.addAll(config.globalAttributes);
      _globalAttributes['user.id'] = _currentUserId!;

      final breadcrumbs = BreadcrumbManager(debugMode: config.debugMode);
      final context = ContextManager(
        sessionManager: _sessionManager!,
        global: _globalAttributes,
      );

      // Build + start the graph (binds the session bookend sink to the
      // Collector), then recover any killed prior session and start a fresh one.
      _wiring = await TelemetryWiring.build(
        config: config,
        session: _sessionManager!,
        context: context,
        breadcrumbs: breadcrumbs,
      );

      await _sessionManager!.recoverAndStart();
      _currentSessionId = _sessionManager!.currentSessionId;

      if (config.enableCrashReporting) {
        _installGlobalCrashHandler();
        await _drainNativeCrashes();
      }

      if (config.enableLocalReporting) {
        await _setupLocalReporting();
      }

      _initialized = true;

      // Emitted direct (no counter bump), matching v1.5.2.
      _wiring!.collector
          .add(EdgeEvent.event('telemetry.initialized', attributes: {
        'service_name': config.serviceName,
        'debug_mode': config.debugMode.toString(),
        'network_monitoring': config.enableNetworkMonitoring.toString(),
        'performance_monitoring': config.enablePerformanceMonitoring.toString(),
        'navigation_tracking': config.enableNavigationTracking.toString(),
        'http_monitoring': config.enableHttpMonitoring.toString(),
        'local_reporting': config.enableLocalReporting.toString(),
        'json_format': config.useJsonFormat.toString(),
        'user_id_auto_generated': 'true',
        'initialization_timestamp': DateTime.now().toIso8601String(),
      }));

      if (config.debugMode) {
        print('✅ EdgeTelemetry initialized successfully');
        print('📱 Service: ${config.serviceName}');
        print('🔗 Endpoint: ${config.endpoint}');
        print(
            '🆔 Device ID: ${_globalAttributes['device.id'] ?? 'Not available'}');
        print('👤 User ID: $_currentUserId');
        print('🔄 Session ID: ${_sessionManager!.currentSessionId}');
      }
    } catch (e, stackTrace) {
      if (config.debugMode) {
        print('❌ EdgeTelemetry initialization failed: $e');
        print('Stack trace: $stackTrace');
      }
      rethrow;
    }
  }

  /// Pull native crashes surfaced by the OS since last launch, once on init.
  ///
  /// No-op until the Phase-4 native plugin registers the channel — the drain
  /// returns `[]` and nothing is sent. When the plugin lands, Phase 4 wires the
  /// returned payloads into the immediate crash rail here.
  Future<void> _drainNativeCrashes() async {
    final crashes = await _wiring!.nativeCrash.drainNativeCrashes();
    // ponytail: drop until Phase 4; routing to app.crash lands with the native
    // plugin + the app.crash wire event (spec #15 Phase 4). Contract-only here.
    if (_config?.debugMode == true && crashes.isNotEmpty) {
      print('📥 Drained ${crashes.length} native crash(es)');
    }
  }

  /// Funnel every auto-catchable Dart error path into the one immediate
  /// `app.crash` rail, each tagged with its `crash.source`. `runZonedGuarded`
  /// (source `zone`) can't be retrofitted onto the already-running zone from
  /// here — a consumer routes it via `trackError`; the source token is part of
  /// the taxonomy for that path.
  void _installGlobalCrashHandler() {
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      _emitCrash(details.exception,
          stackTrace: details.stack, source: 'flutter_error');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _emitCrash(error, stackTrace: stack, source: 'platform_dispatcher');
      return true;
    };

    // Uncaught errors from the root isolate arrive as a 2-element list of
    // strings [errorString, stackTraceString].
    final port = RawReceivePort((dynamic message) {
      final pair = (message as List).cast<String?>();
      _emitCrash(
        pair.isNotEmpty ? (pair[0] ?? 'Isolate error') : 'Isolate error',
        stackTrace: (pair.length > 1 && pair[1] != null)
            ? StackTrace.fromString(pair[1]!)
            : null,
        source: 'isolate',
      );
    });
    Isolate.current.addErrorListener(port.sendPort);
    _isolateErrorPort = port;
  }

  /// The one internal crash entry point — builds the `app.crash` event via
  /// [CrashReporting] and hands it to the Collector's immediate rail.
  void _emitCrash(Object error,
      {StackTrace? stackTrace,
      String? source,
      Map<String, String>? attributes}) {
    if (_wiring == null) return;
    _wiring!.collector.add(_wiring!.crashReporting.buildCrashEvent(error,
        stackTrace: stackTrace, source: source, attributes: attributes));
  }

  // ==================== CORE TRACKING API ====================

  /// Track a custom event with flexible attribute support.
  void trackEvent(String eventName, {dynamic attributes}) {
    _ensureInitialized();
    final stringAttributes = _convertToStringMap(attributes);

    // Host names are arbitrary → wrap into the canon `custom_event` with the
    // host-supplied name carried in `event.name` (mapping §2).
    _wiring!.collector.add(EdgeEvent.event('custom_event',
        attributes: {'event.name': eventName, ...stringAttributes},
        countsToSession: true));

    if (isLocalReportingEnabled && _currentSessionId != null) {
      final event = TelemetryEvent(
        id: _generateEventId(),
        sessionId: _currentSessionId!,
        eventName: eventName,
        timestamp: DateTime.now(),
        attributes: {..._wiring!.context.snapshot(), ...stringAttributes},
        userId: _currentUserId,
      );
      _reportStorage!.storeEvent(event).catchError((e) {
        if (_config?.debugMode == true) print('⚠️ Failed to store event: $e');
      });
    }
  }

  /// Track a custom metric with flexible attribute support.
  void trackMetric(String metricName, double value, {dynamic attributes}) {
    _ensureInitialized();
    final stringAttributes = _convertToStringMap(attributes);

    _wiring!.collector.add(EdgeEvent.metric(metricName, value,
        attributes: stringAttributes, countsToSession: true));

    if (isLocalReportingEnabled && _currentSessionId != null) {
      final metric = TelemetryMetric(
        id: _generateMetricId(),
        sessionId: _currentSessionId!,
        metricName: metricName,
        value: value,
        timestamp: DateTime.now(),
        attributes: {..._wiring!.context.snapshot(), ...stringAttributes},
        userId: _currentUserId,
      );
      _reportStorage!.storeMetric(metric).catchError((e) {
        if (_config?.debugMode == true) print('⚠️ Failed to store metric: $e');
      });
    }
  }

  /// Track an error or exception (immediate crash rail).
  void trackError(Object error,
      {StackTrace? stackTrace, Map<String, String>? attributes}) {
    _ensureInitialized();
    _emitCrash(error, stackTrace: stackTrace, attributes: attributes);
  }

  // ==================== DEPRECATED SPAN NO-OPS ====================

  /// Execute a function — no longer records a span.
  @Deprecated(
      'withSpan no longer records a span; it just runs your function. Remove it or use trackEvent. Removed in v3.0.0.')
  Future<T> withSpan<T>(
    String spanName,
    Future<T> Function() operation, {
    Map<String, String>? attributes,
  }) async {
    _ensureInitialized();
    _warnDeprecatedOnce('withSpan',
        'withSpan no longer records a span; it just runs your function. Remove it or use trackEvent. Removed in v3.0.0.');
    return await operation();
  }

  /// Execute a network operation — no longer records a span.
  @Deprecated(
      'withNetworkSpan no longer records a span; it just runs your function. Remove it or use trackEvent. Removed in v3.0.0.')
  Future<T> withNetworkSpan<T>(
    String operationName,
    String url,
    String method,
    Future<T> Function() operation, {
    Map<String, String>? attributes,
  }) async {
    _ensureInitialized();
    _warnDeprecatedOnce('withNetworkSpan',
        'withNetworkSpan no longer records a span; it just runs your function. Remove it or use trackEvent. Removed in v3.0.0.');
    return await operation();
  }

  // ==================== USER PROFILE API ====================

  /// Set user profile information (name, email, phone).
  void setUserProfile({
    String? name,
    String? email,
    String? phone,
    Map<String, String>? customAttributes,
  }) {
    _ensureInitialized();
    _userProfile.clear();
    if (name != null) _userProfile['user.name'] = name;
    if (email != null) _userProfile['user.email'] = email;
    if (phone != null) _userProfile['user.phone'] = phone;
    if (customAttributes != null) _userProfile.addAll(customAttributes);

    final profileVersion = _getNextProfileVersion();

    final profileEventAttributes = <String, String>{
      'user.id': _currentUserId!,
      'user.profile_version': profileVersion.toString(),
      'user.profile_updated_at': DateTime.now().toIso8601String(),
    };
    if (name != null) profileEventAttributes['user.name'] = name;
    if (email != null) profileEventAttributes['user.email'] = email;
    if (phone != null) profileEventAttributes['user.phone'] = phone;
    if (customAttributes != null) {
      for (final entry in customAttributes.entries) {
        final key =
            entry.key.startsWith('user.') ? entry.key : 'user.${entry.key}';
        profileEventAttributes[key] = entry.value;
      }
    }

    // Canon: one `user.profile.update` (folds v1 profile_updated/set/cleared).
    _emitProfileEvent('user.profile.update', profileEventAttributes);
  }

  /// Emit a profile event direct — no session-counter bump, no local store —
  /// matching v1.5.2, which sent these via the tracker (not the public API).
  /// Batched-but-bypass: an identity mutation isn't time-critical, but must land
  /// even in a sampled-out session (#25).
  void _emitProfileEvent(String eventName, Map<String, String> attributes) {
    _wiring!.collector.add(EdgeEvent.event(eventName,
        attributes: attributes, countsToSession: false, bypassSampling: true));
  }

  /// Clear user profile (but keep auto-generated user ID).
  void clearUserProfile() {
    _ensureInitialized();
    _userProfile.clear();
    final profileVersion = _getNextProfileVersion();

    _emitProfileEvent('user.profile.update', {
      'user.id': _currentUserId!,
      'user.profile_version': profileVersion.toString(),
      'user.profile_updated_at': DateTime.now().toIso8601String(),
    });
  }

  String? get currentUserId => _currentUserId;
  Map<String, String> get currentUserProfile => Map.unmodifiable(_userProfile);
  Map<String, dynamic> get currentSessionInfo =>
      _sessionManager?.getSessionStats() ?? {};

  int _getNextProfileVersion() {
    _profileVersion++;
    _saveProfileVersion();
    return _profileVersion;
  }

  void _saveProfileVersion() {
    try {
      SharedPreferences.getInstance().then((prefs) {
        prefs.setInt(_profileVersionKey, _profileVersion);
      });
    } catch (e) {
      if (_config?.debugMode == true) {
        print('⚠️ Failed to save profile version: $e');
      }
    }
  }

  Future<void> _loadProfileVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _profileVersion = prefs.getInt(_profileVersionKey) ?? 0;
    } catch (e) {
      _profileVersion = 0;
    }
  }

  // ==================== CONTEXT / STATUS GETTERS ====================

  /// Get the navigation observer for MaterialApp.
  EdgeNavigationObserver get navigationObserver {
    _ensureInitialized();
    final observer = _wiring!.navigationObserver;
    if (observer == null) {
      throw StateError(
          'Navigation tracking is disabled. Set enableNavigationTracking: true.');
    }
    return observer;
  }

  /// Get current network type.
  String get currentNetworkType => _wiring?.context.networkType ?? 'unknown';

  /// Get connectivity information.
  Map<String, String> getConnectivityInfo() =>
      _wiring?.networkHook?.getConnectivityInfo() ??
      const {'network.type': 'unknown'};

  bool get isInitialized => _initialized;
  TelemetryConfig? get config => _config;

  /// Get global attributes (includes live session details).
  Map<String, String> get globalAttributes =>
      Map.unmodifiable(_wiring?.context.snapshot() ?? const {});

  // ==================== BREADCRUMB API ====================

  void addBreadcrumb(
    String message, {
    required String category,
    BreadcrumbLevel level = BreadcrumbLevel.info,
    Map<String, String>? data,
  }) {
    _ensureInitialized();
    _wiring!.breadcrumbs
        .addBreadcrumb(message, category: category, level: level, data: data);
  }

  void addNavigationBreadcrumb(String route, {Map<String, String>? data}) {
    _ensureInitialized();
    _wiring!.breadcrumbs.addNavigation(route, data: data);
  }

  void addUserActionBreadcrumb(String action, {Map<String, String>? data}) {
    _ensureInitialized();
    _wiring!.breadcrumbs.addUserAction(action, data: data);
  }

  void addSystemBreadcrumb(String event,
      {BreadcrumbLevel level = BreadcrumbLevel.info,
      Map<String, String>? data}) {
    _ensureInitialized();
    _wiring!.breadcrumbs.addSystemEvent(event, level: level, data: data);
  }

  void addNetworkBreadcrumb(String event,
      {BreadcrumbLevel level = BreadcrumbLevel.info,
      Map<String, String>? data}) {
    _ensureInitialized();
    _wiring!.breadcrumbs.addNetworkEvent(event, level: level, data: data);
  }

  void addUIBreadcrumb(String event, {Map<String, String>? data}) {
    _ensureInitialized();
    _wiring!.breadcrumbs.addUIEvent(event, data: data);
  }

  void addCustomBreadcrumb(String message,
      {BreadcrumbLevel level = BreadcrumbLevel.info,
      Map<String, String>? data}) {
    _ensureInitialized();
    _wiring!.breadcrumbs.addCustom(message, level: level, data: data);
  }

  List<Breadcrumb> getBreadcrumbs() {
    _ensureInitialized();
    return _wiring!.breadcrumbs.getBreadcrumbs();
  }

  void clearBreadcrumbs() {
    _ensureInitialized();
    _wiring!.breadcrumbs.clear();
  }

  // ==================== REPORT API ====================

  Future<void> _setupLocalReporting() async {
    try {
      _reportStorage = MemoryReportStorage();
      await _reportStorage!.initialize();
      _reportGenerator = SimpleReportGenerator(_reportStorage!);
      await _startNewSession();
    } catch (e) {
      if (_config!.debugMode) print('⚠️ Local reporting setup failed: $e');
    }
  }

  Future<void> _startNewSession() async {
    if (_reportStorage == null) return;
    _currentSession = TelemetrySession(
      sessionId: _currentSessionId!,
      startTime: DateTime.now(),
      userId: _currentUserId,
      deviceAttributes: Map.from(_globalAttributes),
      appAttributes: {
        'app.name': _globalAttributes['app.name'] ?? 'unknown',
        'app.version': _globalAttributes['app.version'] ?? 'unknown',
      },
    );
    await _reportStorage!.startSession(_currentSession!);
  }

  Future<GeneratedReport> generateSummaryReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    _ensureReportingEnabled();
    return await _reportGenerator!.generateSummaryReport(
        startTime: startTime, endTime: endTime, title: title);
  }

  Future<GeneratedReport> generatePerformanceReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    _ensureReportingEnabled();
    return await _reportGenerator!.generatePerformanceReport(
        startTime: startTime, endTime: endTime, title: title);
  }

  Future<GeneratedReport> generateUserBehaviorReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    _ensureReportingEnabled();
    return await _reportGenerator!.generateUserBehaviorReport(
        startTime: startTime, endTime: endTime, title: title);
  }

  Future<String> exportReportToFile(
      GeneratedReport report, String filePath) async {
    _ensureReportingEnabled();
    final content = report.format == 'json'
        ? report.toJson().toString()
        : report.data.toString();
    await File(filePath).writeAsString(content);
    return filePath;
  }

  bool get isLocalReportingEnabled =>
      _reportStorage != null && _reportGenerator != null;

  TelemetrySession? getCurrentSession() => _currentSession;

  // ==================== LIFECYCLE ====================

  /// Dispose all hooks and flush the pipeline (additive — no compat break).
  void shutdown() {
    _wiring?.pipeline.flush();
    _wiring?.disposeAll();
  }

  /// Dispose all resources (call when the app is shutting down).
  void dispose() {
    _sessionManager?.endSession();

    if (_isolateErrorPort != null) {
      Isolate.current.removeErrorListener(_isolateErrorPort!.sendPort);
      _isolateErrorPort!.close();
      _isolateErrorPort = null;
    }

    if (isLocalReportingEnabled && _currentSessionId != null) {
      _currentSession = _currentSession?.copyWith(endTime: DateTime.now());
      _reportStorage?.endSession(_currentSessionId!).catchError((e) {
        if (_config?.debugMode == true) print('⚠️ Failed to end session: $e');
      });
    }
    _reportStorage?.dispose();

    _wiring?.disposeAll();
    _initialized = false;

    if (_config?.debugMode == true) print('🧹 EdgeTelemetry disposed');
  }

  // ==================== INTERNAL HELPERS ====================

  Map<String, String> _convertToStringMap(dynamic attributes) {
    if (attributes == null) return {};
    if (attributes is Map<String, String>) return attributes;
    if (attributes is Map<String, dynamic>) {
      return attributes.map((k, v) => MapEntry(k, _valueToString(v)));
    }
    if (attributes is Map) {
      return attributes
          .map((k, v) => MapEntry(k.toString(), _valueToString(v)));
    }
    if (_hasToJsonMethod(attributes)) {
      try {
        final jsonMap = (attributes as dynamic).toJson();
        if (jsonMap is Map) {
          return jsonMap
              .map((k, v) => MapEntry(k.toString(), _valueToString(v)));
        }
      } catch (e) {
        if (_config?.debugMode == true) {
          print('⚠️ Failed to convert toJson(): $e');
        }
      }
    }
    return _objectToMap(attributes);
  }

  String _valueToString(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return value;
    if (value is num) return value.toString();
    if (value is bool) return value.toString();
    if (value is DateTime) return value.toIso8601String();
    if (value is Duration) return value.inMilliseconds.toString();
    if (value is List) return value.join(',');
    if (value is Map) return value.toString();
    return value.toString();
  }

  bool _hasToJsonMethod(Object obj) {
    try {
      return obj.runtimeType.toString().contains('toJson') ||
          (obj as dynamic).toJson != null;
    } catch (e) {
      return false;
    }
  }

  Map<String, String> _objectToMap(Object obj) {
    final result = <String, String>{};
    try {
      final objString = obj.toString();
      if (!objString.startsWith('Instance of ')) {
        result['object'] = objString;
      } else {
        result['type'] = obj.runtimeType.toString();
        result['value'] = objString;
      }
      if (obj is Enum) {
        result['enum_name'] = obj.toString().split('.').last;
      }
    } catch (e) {
      result['error'] = 'Failed to convert object: $e';
    }
    return result;
  }

  /// Format: `session_<epochMs>_<16hex>_<platform>` — the family session leg of
  /// the identity contract (ticket #20).
  String _generateSessionId() =>
      'session_${DateTime.now().millisecondsSinceEpoch}_${secureHex16()}_${platformTag()}';

  String _generateEventId() =>
      'event_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';
  String _generateMetricId() =>
      'metric_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
          'EdgeTelemetry is not initialized. Call EdgeTelemetry.initialize() first.');
    }
  }

  void _ensureReportingEnabled() {
    if (!isLocalReportingEnabled) {
      throw StateError(
        'Local reporting is not enabled. Set enableLocalReporting: true when initializing EdgeTelemetry.',
      );
    }
  }
}
