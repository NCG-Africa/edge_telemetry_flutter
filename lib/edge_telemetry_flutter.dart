// lib/edge_telemetry_flutter.dart - Enhanced version with automatic HTTP monitoring

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:edge_telemetry_flutter/src/collectors/flutter_device_info_collector.dart';
import 'package:edge_telemetry_flutter/src/core/config/telemetry_config.dart';
import 'package:edge_telemetry_flutter/src/core/interfaces/device_info_collector.dart';
import 'package:edge_telemetry_flutter/src/core/interfaces/event_tracker.dart';
import 'package:edge_telemetry_flutter/src/core/interfaces/network_monitor.dart';
import 'package:edge_telemetry_flutter/src/core/interfaces/performance_monitor.dart';
import 'package:edge_telemetry_flutter/src/core/interfaces/report_generator.dart';
import 'package:edge_telemetry_flutter/src/core/interfaces/report_storage.dart';
import 'package:edge_telemetry_flutter/src/core/models/generated_report.dart';
import 'package:edge_telemetry_flutter/src/core/models/report_data.dart';
import 'package:edge_telemetry_flutter/src/core/models/telemetry_session.dart';
import 'package:edge_telemetry_flutter/src/http/json_http_client.dart';
import 'package:edge_telemetry_flutter/src/http/telemetry_http_overrides.dart'; // NEW
import 'package:edge_telemetry_flutter/src/managers/event_tracker_impl.dart';
import 'package:edge_telemetry_flutter/src/managers/json_event_tracker.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/span_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/user_id_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/breadcrumb_manager.dart';
import 'package:edge_telemetry_flutter/src/core/models/breadcrumb.dart';
import 'package:edge_telemetry_flutter/src/monitors/flutter_network_monitor.dart'
    as network_monitor;
import 'package:edge_telemetry_flutter/src/monitors/flutter_performance_monitor.dart';
import 'package:edge_telemetry_flutter/src/reports/simple_report_generator.dart';
import 'package:edge_telemetry_flutter/src/storage/memory_report_storage.dart';
import 'package:edge_telemetry_flutter/src/widgets/edge_navigation_observer.dart'
    as nav_widget;
import 'package:flutter/cupertino.dart';
import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart' as otel_sdk;
import 'package:shared_preferences/shared_preferences.dart';

/// Main EdgeTelemetry class with automatic HTTP monitoring and enhanced session tracking
class EdgeTelemetry {
  static EdgeTelemetry? _instance;
  static EdgeTelemetry get instance => _instance ??= EdgeTelemetry._();

  EdgeTelemetry._();

  // Core components
  SpanManager? _spanManager;
  late EventTracker _eventTracker;
  late nav_widget.EdgeNavigationObserver _navigationObserver;

  // User and session management
  late UserIdManager _userIdManager;
  late SessionManager _sessionManager;
  String? _currentUserId;

  // User profile data (separate from ID)
  final Map<String, String> _userProfile = {};

  // Profile versioning for conflict resolution
  int _profileVersion = 0;
  static const String _profileVersionKey = 'edge_telemetry_profile_version';

  // Monitoring components
  NetworkMonitor? _networkMonitor;
  PerformanceMonitor? _performanceMonitor;
  DeviceInfoCollector? _deviceInfoCollector;

  // Report system components
  ReportStorage? _reportStorage;
  ReportGenerator? _reportGenerator;
  TelemetrySession? _currentSession;
  String? _currentSessionId;

  // NEW: HTTP monitoring state
  bool _httpMonitoringInstalled = false;

  // Breadcrumb management
  late BreadcrumbManager _breadcrumbManager;

  // State
  bool _initialized = false;
  TelemetryConfig? _config;
  Map<String, String> _globalAttributes = {};

  // Subscriptions
  StreamSubscription<String>? _networkSubscription;

  /// Initialize EdgeTelemetry with automatic monitoring capabilities
  ///
  /// This is the ONE-CALL setup that enables all automatic telemetry:
  /// - Crash reporting via global error handlers
  /// - HTTP request monitoring via HttpOverrides.global
  /// - Session tracking and user identification
  /// - Performance and network monitoring
  static Future<void> initialize({
    required String endpoint,
    required String serviceName,
    bool debugMode = false,
    Map<String, String>? globalAttributes,
    Duration? batchTimeout,
    int? maxBatchSize,
    bool enableNetworkMonitoring = true,
    bool enablePerformanceMonitoring = true,
    bool enableNavigationTracking = true,
    bool enableHttpMonitoring = true, // NEW: Enable automatic HTTP monitoring
    bool enableCrashReporting = true,
    bool enableLocalReporting = false,
    String? reportStoragePath,
    Duration? dataRetentionPeriod,
    bool useJsonFormat = true, // Default to JSON for simplicity
    int eventBatchSize = 30,
    @Deprecated('runAppCallback is deprecated. Crash handlers are now installed automatically.')
    VoidCallback? runAppCallback,
  }) async {
    final config = TelemetryConfig(
      endpoint: endpoint,
      serviceName: serviceName,
      debugMode: debugMode,
      globalAttributes: globalAttributes ?? {},
      batchTimeout: batchTimeout ?? const Duration(seconds: 5),
      maxBatchSize: maxBatchSize ?? 512,
      enableNetworkMonitoring: enableNetworkMonitoring,
      enablePerformanceMonitoring: enablePerformanceMonitoring,
      enableNavigationTracking: enableNavigationTracking,
      enableErrorReporting: true, // Always enable error reporting
      enableLocalReporting: enableLocalReporting,
      reportStoragePath: reportStoragePath,
      dataRetentionPeriod: dataRetentionPeriod ?? const Duration(days: 30),
      useJsonFormat: useJsonFormat,
      eventBatchSize: eventBatchSize,
      // Add HTTP monitoring config
      enableHttpMonitoring: enableHttpMonitoring,
      enableCrashReporting: enableCrashReporting,
    );

    await instance._setup(config);
    
    // Backward compatibility: handle runAppCallback if provided
    if (runAppCallback != null) {
      if (debugMode) {
        print('⚠️ DEPRECATED: runAppCallback parameter is deprecated and will be removed in v2.0.0');
        print('   Crash handlers are now installed automatically during initialization.');
        print('   Simply remove the runAppCallback parameter from EdgeTelemetry.initialize()');
      }
      // Execute the callback for backward compatibility
      runAppCallback();
    }
  }

  /// Setup global crash and error handling
  void _installGlobalCrashHandler() {
    // Capture Flutter framework errors
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      trackError(details.exception, stackTrace: details.stack);
    };

    // Capture Dart runtime errors (async exceptions, unhandled errors)
    PlatformDispatcher.instance.onError = (error, stack) {
      trackError(error, stackTrace: stack);
      return true; // Mark as handled
    };
  }

  /// Internal setup method - enhanced with HTTP monitoring
  Future<void> _setup(TelemetryConfig config) async {
    if (_initialized) return;

    _config = config;

    try {
      // Initialize user ID manager and get/generate user ID
      await _initializeUserId();

      // Initialize session manager
      await _initializeSession();

      // Load profile version from storage
      await _loadProfileVersion();

      // Collect device information
      await _collectDeviceInfo();

      // Setup telemetry (JSON or OpenTelemetry)
      if (config.useJsonFormat) {
        await _setupJsonTelemetry();
      } else {
        await _setupTelemetry();
      }

      // Initialize core managers
      _initializeManagers();

      // Initialize breadcrumb manager
      _breadcrumbManager = BreadcrumbManager(debugMode: config.debugMode);

      // Setup monitoring components
      await _setupMonitoring();

      // Setup automatic HTTP monitoring
      if (config.enableHttpMonitoring) {
        _setupHttpMonitoring();
      }

      // Setup crash handlers
      if (config.enableCrashReporting) {
        _installGlobalCrashHandler();
      }

      // Setup navigation tracking
      _setupNavigationTracking();

      // Setup local reporting (if enabled)
      if (config.enableLocalReporting) {
        await _setupLocalReporting();
      }

      _initialized = true;

      // Track initialization
      _eventTracker.trackEvent('telemetry.initialized', attributes: {
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
      });

      if (config.debugMode) {
        print('✅ EdgeTelemetry initialized successfully');
        print('📱 Service: ${config.serviceName}');
        print('🔗 Endpoint: ${config.endpoint}');
        print('📡 Format: ${config.useJsonFormat ? 'JSON' : 'OpenTelemetry'}');
        print('🆔 Device ID: ${_globalAttributes['device.id'] ?? 'Not available'}');
        print('👤 User ID: $_currentUserId');
        print('🔄 Session ID: ${_sessionManager.currentSessionId}');
        print('📊 Session Stats: ${_sessionManager.getSessionStats()}');
        print(
            '🌐 HTTP Monitoring: ${config.enableHttpMonitoring ? 'Enabled' : 'Disabled'}');
        print(
            '📊 Device: ${_globalAttributes['device.model'] ?? 'Unknown'} (${_globalAttributes['device.platform'] ?? 'Unknown'})');
        print(
            '📦 App: ${_globalAttributes['app.name'] ?? 'Unknown'} v${_globalAttributes['app.version'] ?? 'Unknown'}');
        if (config.enableLocalReporting) {
          print('📋 Local reporting: Enabled');
        }
      }
    } catch (e, stackTrace) {
      if (config.debugMode) {
        print('❌ EdgeTelemetry initialization failed: $e');
        print('Stack trace: $stackTrace');
      }
      rethrow;
    }
  }

  /// NEW: Setup automatic HTTP monitoring
  void _setupHttpMonitoring() {
    if (_httpMonitoringInstalled) return;

    TelemetryHttpOverrides.installGlobal(
      onRequestComplete: (HttpRequestTelemetry httpTelemetry) {
        _trackHttpRequest(httpTelemetry);
      },
      debugMode: _config?.debugMode ?? false,
    );

    _httpMonitoringInstalled = true;

    if (_config?.debugMode == true) {
      print('🌐 HTTP monitoring installed globally');
      print('📡 All HTTP requests will be automatically tracked');
    }
  }

  /// Track HTTP request telemetry
  void _trackHttpRequest(HttpRequestTelemetry httpTelemetry) {
    // Track as an event
    trackEvent('http.request', attributes: httpTelemetry.toAttributes());

    // Track response time as a metric
    trackMetric(
      'http.response_time',
      httpTelemetry.duration.inMilliseconds.toDouble(),
      attributes: {
        'http.method': httpTelemetry.method,
        'http.status_code': httpTelemetry.statusCode.toString(),
        'http.category': httpTelemetry.category,
        'http.performance': httpTelemetry.performanceCategory,
      },
    );

    // Track errors separately
    if (!httpTelemetry.isSuccess) {
      trackEvent('http.error', attributes: {
        ...httpTelemetry.toAttributes(),
        'error.type': 'http_error',
        'error.category': httpTelemetry.category,
      });
    }

    // Track slow requests
    if (httpTelemetry.duration.inMilliseconds > 2000) {
      trackEvent('http.slow_request', attributes: {
        ...httpTelemetry.toAttributes(),
        'performance.category': 'slow',
      });
    }
  }

  /// Initialize user ID (auto-generated and persistent)
  Future<void> _initializeUserId() async {
    _userIdManager = UserIdManager();
    _currentUserId = await _userIdManager.getUserId();
  }

  /// Initialize session manager and start session
  Future<void> _initializeSession() async {
    _sessionManager = SessionManager();
    _currentSessionId = _generateSessionId();
    await _sessionManager.startSession(_currentSessionId!);
  }

  /// Collect device and app information
  Future<void> _collectDeviceInfo() async {
    _deviceInfoCollector = FlutterDeviceInfoCollector();
    _globalAttributes = await _deviceInfoCollector!.collectDeviceInfo();
    _globalAttributes.addAll(_config!.globalAttributes);

    // Add auto-generated user ID to global attributes
    _globalAttributes['user.id'] = _currentUserId!;
    
    // Verify device ID is present and log status
    if (_globalAttributes.containsKey('device.id')) {
      final deviceId = _globalAttributes['device.id']!;
      if (_config!.debugMode) {
        print('🆔 Device ID collected: $deviceId');
        if (_isValidDeviceId(deviceId)) {
          print('✅ Device ID format validated');
        } else {
          print('⚠️ Device ID format validation failed');
        }
      }
    } else {
      if (_config!.debugMode) {
        print('⚠️ Device ID missing from device info collection');
      }
    }
  }

  /// Get enriched attributes with session details
  Map<String, String> _getEnrichedAttributes(
      [Map<String, String>? customAttributes]) {
    return {
      ..._globalAttributes,
      ..._sessionManager.getSessionAttributes(),
      'network.type': _networkMonitor?.currentNetworkType ?? 'unknown',
      ...?customAttributes,
    };
  }

  /// Setup OpenTelemetry SDK
  Future<void> _setupTelemetry() async {
    final processors = [
      otel_sdk.BatchSpanProcessor(
        otel_sdk.CollectorExporter(Uri.parse(_config!.endpoint)),
      ),
    ];

    final tracerProvider = otel_sdk.TracerProviderBase(processors: processors);
    registerGlobalTracerProvider(tracerProvider);

    final tracer = globalTracerProvider.getTracer(_config!.serviceName);
    _spanManager = SpanManager(tracer, _globalAttributes);

    // Set user context in span manager with auto-generated ID
    _spanManager!.setUser(userId: _currentUserId!);
  }

  /// Setup JSON telemetry instead of OpenTelemetry
  Future<void> _setupJsonTelemetry() async {
    final jsonClient = JsonHttpClient(endpoint: _config!.endpoint);
    _eventTracker = JsonEventTracker(
      jsonClient,
      () => _getEnrichedAttributes(),
      batchSize: _config!.eventBatchSize,
      debugMode: _config!.debugMode,
    );

    if (_config!.debugMode) {
      print('📡 JSON telemetry configured for endpoint: ${_config!.endpoint}');
      print('📦 Batch size: ${_config!.eventBatchSize} events');
    }
  }

  /// Initialize core managers
  void _initializeManagers() {
    // Only initialize EventTrackerImpl for OpenTelemetry mode
    if (!_config!.useJsonFormat) {
      _eventTracker = EventTrackerImpl(_spanManager!);
    }
  }

  /// Setup monitoring components
  Future<void> _setupMonitoring() async {
    // Network monitoring
    if (_config!.enableNetworkMonitoring) {
      _networkMonitor =
          network_monitor.FlutterNetworkMonitor(eventTracker: _eventTracker);
      await _networkMonitor!.initialize();

      // Listen to network changes and update global attributes
      _networkSubscription =
          _networkMonitor!.networkTypeChanges.listen((networkType) {
        _globalAttributes['network.type'] = networkType;

        // Only update spanManager for OpenTelemetry mode
        if (!_config!.useJsonFormat && _spanManager != null) {
          _spanManager = SpanManager(
              globalTracerProvider.getTracer(_config!.serviceName),
              _globalAttributes);
          // Maintain user context after network changes
          _spanManager!.setUser(userId: _currentUserId!);
          _applyUserProfile();
        }
      });
    }

    // Performance monitoring
    if (_config!.enablePerformanceMonitoring) {
      _performanceMonitor =
          FlutterPerformanceMonitor(eventTracker: _eventTracker);
      await _performanceMonitor!.initialize();
    }
  }

  /// Setup navigation tracking
  void _setupNavigationTracking() {
    if (_config!.enableNavigationTracking) {
      _navigationObserver = nav_widget.EdgeNavigationObserver(
        onEvent: (eventName, {attributes}) {
          // Track screen visits for session
          if (eventName == 'navigation.route_change' &&
              attributes != null &&
              attributes.containsKey('navigation.to')) {
            _sessionManager.recordScreen(attributes['navigation.to']!);
            
            // Auto-track navigation breadcrumb
            _breadcrumbManager.addNavigation(
              attributes['navigation.to']!,
              data: {
                'from': attributes['navigation.from'] ?? 'unknown',
                'method': attributes['navigation.method'] ?? 'unknown',
              },
            );
          }

          // Track the event
          _eventTracker.trackEvent(eventName, attributes: attributes);
        },
        onMetric: _eventTracker.trackMetric,
        onSpanStart: (spanName, {attributes}) {
          // Only use spanManager for OpenTelemetry mode
          if (!_config!.useJsonFormat && _spanManager != null) {
            final span =
                _spanManager!.createSpan(spanName, attributes: attributes);
            final routeName = spanName.startsWith('screen.')
                ? spanName.substring(7)
                : spanName;
            _navigationObserver.registerScreenSpan(routeName, span);
          }
        },
        onSpanEnd: (span) {
          // Only use spanManager for OpenTelemetry mode
          if (!_config!.useJsonFormat && _spanManager != null) {
            _spanManager!.endSpan(span);
          }
        },
      );
    }
  }

  // ==================== REPORT SYSTEM METHODS ====================

  /// Setup local reporting
  Future<void> _setupLocalReporting() async {
    try {
      // Initialize storage (using memory storage for now)
      _reportStorage = MemoryReportStorage();
      await _reportStorage!.initialize();

      // Initialize report generator
      _reportGenerator = SimpleReportGenerator(_reportStorage!);

      // Start a new session
      await _startNewSession();

      if (_config!.debugMode) {
        print('📊 Local reporting initialized');
      }
    } catch (e) {
      if (_config!.debugMode) {
        print('⚠️ Local reporting setup failed: $e');
      }
      // Continue without local reporting
    }
  }

  /// Start a new telemetry session
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

  String _generateSessionId() {
    return _generateRandomString(16);
  }

  /// Generate a random alphanumeric string
  String _generateRandomString(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();

    return String.fromCharCodes(Iterable.generate(
        length, (_) => chars.codeUnitAt(random.nextInt(chars.length))));
  }

  // ==================== USER PROFILE API ====================

  /// Get the next profile version number
  int _getNextProfileVersion() {
    _profileVersion++;
    _saveProfileVersion();
    return _profileVersion;
  }

  /// Save profile version to persistent storage
  void _saveProfileVersion() {
    try {
      // Use SharedPreferences to persist profile version
      SharedPreferences.getInstance().then((prefs) {
        prefs.setInt(_profileVersionKey, _profileVersion);
      });
    } catch (e) {
      if (_config?.debugMode == true) {
        print('⚠️ Failed to save profile version: $e');
      }
    }
  }

  /// Load profile version from persistent storage
  Future<void> _loadProfileVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _profileVersion = prefs.getInt(_profileVersionKey) ?? 0;
      if (_config?.debugMode == true) {
        print('📊 Loaded profile version: $_profileVersion');
      }
    } catch (e) {
      _profileVersion = 0;
      if (_config?.debugMode == true) {
        print('⚠️ Failed to load profile version, starting from 0: $e');
      }
    }
  }

  /// Set user profile information (name, email, phone)
  void setUserProfile({
    String? name,
    String? email,
    String? phone,
    Map<String, String>? customAttributes,
  }) {
    _ensureInitialized();

    // Clear existing profile
    _userProfile.clear();

    // Add profile data to global attributes (maintain existing behavior)
    if (name != null) _userProfile['user.name'] = name;
    if (email != null) _userProfile['user.email'] = email;
    if (phone != null) _userProfile['user.phone'] = phone;
    if (customAttributes != null) _userProfile.addAll(customAttributes);

    // Apply to span manager (OpenTelemetry mode)
    _applyUserProfile();

    // NEW: Increment profile version for conflict resolution
    final profileVersion = _getNextProfileVersion();
    
    // NEW: Create dedicated profile update event for backend persistence
    final profileEventAttributes = <String, String>{
      'user.id': _currentUserId!,
      'user.profile_version': profileVersion.toString(),
      'user.profile_updated_at': DateTime.now().toIso8601String(),
    };

    // Add profile fields to event (only non-null values)
    if (name != null) profileEventAttributes['user.name'] = name;
    if (email != null) profileEventAttributes['user.email'] = email;
    if (phone != null) profileEventAttributes['user.phone'] = phone;

    // Add custom attributes with user. prefix for backend processing
    if (customAttributes != null) {
      for (final entry in customAttributes.entries) {
        final key = entry.key.startsWith('user.') ? entry.key : 'user.${entry.key}';
        profileEventAttributes[key] = entry.value;
      }
    }

    // Send dedicated profile update event to backend
    _eventTracker.trackEvent('user.profile_updated', attributes: profileEventAttributes);

    // Keep existing profile set event for backward compatibility/analytics
    _eventTracker.trackEvent('user.profile_set', attributes: {
      'user.has_name': (name != null).toString(),
      'user.has_email': (email != null).toString(),
      'user.has_phone': (phone != null).toString(),
      'user.custom_attributes_count': (customAttributes?.length ?? 0).toString(),
      'profile_timestamp': DateTime.now().toIso8601String(),
      'profile_version': profileVersion.toString(),
    });

    if (_config?.debugMode == true) {
      print('✅ Profile updated and events sent:');
      print('  - user.profile_updated (for backend persistence)');
      print('  - user.profile_set (for analytics)');
      print('  - Profile version: $profileVersion');
      print('  - Fields updated: ${profileEventAttributes.keys.where((k) => k.startsWith('user.') && k != 'user.id' && k != 'user.profile_version' && k != 'user.profile_updated_at').toList()}');
    }
  }

  /// Apply user profile to span manager
  void _applyUserProfile() {
    if (!_config!.useJsonFormat && _spanManager != null) {
      _spanManager!.setUser(
        userId: _currentUserId!,
        email: _userProfile['user.email'],
        name: _userProfile['user.name'],
        customAttributes: {
          if (_userProfile['user.phone'] != null)
            'user.phone': _userProfile['user.phone']!,
          ..._userProfile.entries
              .where((e) =>
                  !['user.email', 'user.name', 'user.phone'].contains(e.key))
              .fold<Map<String, String>>({}, (map, entry) {
            map[entry.key] = entry.value;
            return map;
          }),
        },
      );
    }
  }

  /// Clear user profile (but keep auto-generated user ID)
  void clearUserProfile() {
    _ensureInitialized();

    _userProfile.clear();

    // Reset span manager to just have user ID
    if (!_config!.useJsonFormat && _spanManager != null) {
      _spanManager!.setUser(userId: _currentUserId!);
    }

    // NEW: Increment profile version for clear operation
    final profileVersion = _getNextProfileVersion();
    
    // NEW: Send profile cleared event to backend
    _eventTracker.trackEvent('user.profile_updated', attributes: {
      'user.id': _currentUserId!,
      'user.profile_version': profileVersion.toString(),
      'user.profile_updated_at': DateTime.now().toIso8601String(),
      // Note: No profile fields means they should be cleared
    });

    // Keep existing analytics event
    _eventTracker.trackEvent('user.profile_cleared', attributes: {
      'profile_version': profileVersion.toString(),
    });

    if (_config?.debugMode == true) {
      print('✅ Profile cleared and events sent');
      print('  - Profile version: $profileVersion');
    }
  }

  /// Get current user ID (read-only)
  String? get currentUserId => _currentUserId;

  /// Get current user profile (read-only)
  Map<String, String> get currentUserProfile => Map.unmodifiable(_userProfile);

  /// Get current session information
  Map<String, dynamic> get currentSessionInfo =>
      _sessionManager.getSessionStats();

  // ==================== ENHANCED API WITH SESSION DETAILS ====================

  /// Execute a function within a span with automatic lifecycle management
  Future<T> withSpan<T>(
    String spanName,
    Future<T> Function() operation, {
    Map<String, String>? attributes,
  }) async {
    _ensureInitialized();

    // Only use spanManager in OpenTelemetry mode
    if (!_config!.useJsonFormat && _spanManager != null) {
      return _spanManager!.withSpan(spanName, operation,
          attributes: _getEnrichedAttributes(attributes));
    } else {
      // For JSON mode, just execute the operation
      return await operation();
    }
  }

  /// Execute a network operation with automatic network context
  /// NOTE: This is now mostly for manual tracking, as HTTP monitoring is automatic
  Future<T> withNetworkSpan<T>(
    String operationName,
    String url,
    String method,
    Future<T> Function() operation, {
    Map<String, String>? attributes,
  }) async {
    _ensureInitialized();

    final networkAttributes = {
      'http.url': url,
      'http.method': method,
      'network.operation': operationName,
      'network.tracking_type': 'manual', // Distinguish from automatic tracking
      ...?attributes,
    };

    return withSpan('network.$operationName', operation,
        attributes: networkAttributes);
  }

  /// Track a custom event with flexible attribute support
  ///
  /// [eventName] - Name of the event
  /// [attributes] - Can be:
  ///   - Map<String, String> (traditional)
  ///   - Map<String, dynamic> (flexible - auto-converted)
  ///   - Any object with toJson() method
  ///   - Any object (converted via toString/reflection)
  void trackEvent(String eventName, {dynamic attributes}) {
    _ensureInitialized();

    // Record event in session manager
    _sessionManager.recordEvent();

    // Convert attributes to Map<String, String>
    final Map<String, String> stringAttributes =
        _convertToStringMap(attributes);
    final enrichedAttributes = _getEnrichedAttributes(stringAttributes);

    // Store locally for reports if enabled
    if (isLocalReportingEnabled && _currentSessionId != null) {
      final event = TelemetryEvent(
        id: _generateEventId(),
        sessionId: _currentSessionId!,
        eventName: eventName,
        timestamp: DateTime.now(),
        attributes: enrichedAttributes,
        userId: _currentUserId,
      );

      _reportStorage!.storeEvent(event).catchError((e) {
        if (_config?.debugMode == true) {
          print('⚠️ Failed to store event locally: $e');
        }
      });
    }

    // Continue with normal tracking
    _eventTracker.trackEvent(eventName, attributes: enrichedAttributes);
  }

  /// Track a custom metric with flexible attribute support
  ///
  /// [metricName] - Name of the metric
  /// [value] - Numeric value
  /// [attributes] - Can be:
  ///   - Map<String, String> (traditional)
  ///   - Map<String, dynamic> (flexible - auto-converted)
  ///   - Any object with toJson() method
  ///   - Any object (converted via toString/reflection)
  void trackMetric(String metricName, double value, {dynamic attributes}) {
    _ensureInitialized();

    // Record metric in session manager
    _sessionManager.recordMetric();

    // Convert attributes to Map<String, String>
    final Map<String, String> stringAttributes =
        _convertToStringMap(attributes);
    final enrichedAttributes = _getEnrichedAttributes(stringAttributes);

    // Store locally for reports if enabled
    if (isLocalReportingEnabled && _currentSessionId != null) {
      final metric = TelemetryMetric(
        id: _generateMetricId(),
        sessionId: _currentSessionId!,
        metricName: metricName,
        value: value,
        timestamp: DateTime.now(),
        attributes: enrichedAttributes,
        userId: _currentUserId,
      );

      _reportStorage!.storeMetric(metric).catchError((e) {
        if (_config?.debugMode == true) {
          print('⚠️ Failed to store metric locally: $e');
        }
      });
    }

    // Continue with normal tracking
    _eventTracker.trackMetric(metricName, value,
        attributes: enrichedAttributes);
  }

  /// Convert various attribute types to Map<String, String>
  Map<String, String> _convertToStringMap(dynamic attributes) {
    if (attributes == null) {
      return {};
    }

    // Already a Map<String, String>
    if (attributes is Map<String, String>) {
      return attributes;
    }

    // Map<String, dynamic> - convert values to strings
    if (attributes is Map<String, dynamic>) {
      return attributes
          .map((key, value) => MapEntry(key, _valueToString(value)));
    }

    // Map with other key types - convert both keys and values
    if (attributes is Map) {
      return attributes
          .map((key, value) => MapEntry(key.toString(), _valueToString(value)));
    }

    // Object with toJson() method
    if (attributes is Object && _hasToJsonMethod(attributes)) {
      try {
        final jsonMap = (attributes as dynamic).toJson();
        if (jsonMap is Map) {
          return jsonMap.map(
              (key, value) => MapEntry(key.toString(), _valueToString(value)));
        }
      } catch (e) {
        if (_config?.debugMode == true) {
          print('⚠️ Failed to convert object.toJson(): $e');
        }
      }
    }

    // Object with properties - use reflection-like approach
    if (attributes is Object) {
      return _objectToMap(attributes);
    }

    // Fallback - convert entire object to single attribute
    return {'value': _valueToString(attributes)};
  }

  /// Convert a value to string representation
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

  /// Check if object has toJson method
  bool _hasToJsonMethod(Object obj) {
    try {
      return obj.runtimeType.toString().contains('toJson') ||
          (obj as dynamic).toJson != null;
    } catch (e) {
      return false;
    }
  }

  /// Convert object to map using basic reflection
  Map<String, String> _objectToMap(Object obj) {
    final Map<String, String> result = {};

    try {
      // Get the object's string representation and try to extract meaningful data
      final objString = obj.toString();

      // If it's a custom object with meaningful toString(), use it
      if (!objString.startsWith('Instance of ')) {
        result['object'] = objString;
      } else {
        // Fallback to type name
        result['type'] = obj.runtimeType.toString();
        result['value'] = objString;
      }

      // Try to get some basic properties if it's a common type
      if (obj is Enum) {
        result['enum_name'] = obj.toString().split('.').last;
      }
    } catch (e) {
      result['error'] = 'Failed to convert object: $e';
    }

    return result;
  }

  /// Generate crash fingerprint for grouping similar crashes
  String _generateCrashFingerprint(Object error, StackTrace? stackTrace) {
    final errorType = error.runtimeType.toString();
    final errorMessage = error.toString();
    final topStackFrame = stackTrace?.toString().split('\n').firstWhere(
      (line) => line.trim().isNotEmpty,
      orElse: () => 'no_stack',
    ) ?? 'no_stack';
    
    return '${errorType}_${errorMessage.hashCode}_${topStackFrame.hashCode}';
  }

  /// Track an error or exception
  void trackError(Object error,
      {StackTrace? stackTrace, Map<String, String>? attributes}) {
    _ensureInitialized();

    // Generate crash fingerprint
    final fingerprint = _generateCrashFingerprint(error, stackTrace);
    
    // Add fingerprint to attributes
    final crashAttributes = {
      'crash.fingerprint': fingerprint,
      ...?attributes,
    };

    final enrichedAttributes = _getEnrichedAttributes(crashAttributes);

    _eventTracker.trackError(error,
        stackTrace: stackTrace, attributes: enrichedAttributes);
  }

  /// Create a span manually (for advanced use cases)
  Span? startSpan(String name, {Map<String, String>? attributes}) {
    _ensureInitialized();

    // Only available in OpenTelemetry mode
    if (!_config!.useJsonFormat && _spanManager != null) {
      return _spanManager!
          .createSpan(name, attributes: _getEnrichedAttributes(attributes));
    }
    return null;
  }

  /// End a span manually (for advanced use cases)
  void endSpan(Span? span) {
    if (span == null) return;
    _ensureInitialized();

    // Only available in OpenTelemetry mode
    if (!_config!.useJsonFormat && _spanManager != null) {
      _spanManager!.endSpan(span);
    }
  }

  /// Get the navigation observer for MaterialApp
  nav_widget.EdgeNavigationObserver get navigationObserver {
    _ensureInitialized();
    return _navigationObserver;
  }

  /// Get current network type
  String get currentNetworkType {
    return _networkMonitor?.currentNetworkType ?? 'unknown';
  }

  /// Get connectivity information
  Map<String, String> getConnectivityInfo() {
    if (_networkMonitor is network_monitor.FlutterNetworkMonitor) {
      return (_networkMonitor as network_monitor.FlutterNetworkMonitor)
          .getConnectivityInfo();
    }
    return {'network.type': 'unknown'};
  }

  /// Check if telemetry is initialized
  bool get isInitialized => _initialized;

  /// Get current configuration
  TelemetryConfig? get config => _config;

  /// Get global attributes (now includes session details)
  Map<String, String> get globalAttributes =>
      Map.unmodifiable(_getEnrichedAttributes());

  // ==================== BREADCRUMB API METHODS ====================

  /// Add a breadcrumb for crash context
  void addBreadcrumb(
    String message, {
    required String category,
    BreadcrumbLevel level = BreadcrumbLevel.info,
    Map<String, String>? data,
  }) {
    _ensureInitialized();
    _breadcrumbManager.addBreadcrumb(
      message,
      category: category,
      level: level,
      data: data,
    );
  }

  /// Add navigation breadcrumb
  void addNavigationBreadcrumb(String route, {Map<String, String>? data}) {
    _ensureInitialized();
    _breadcrumbManager.addNavigation(route, data: data);
  }

  /// Add user action breadcrumb
  void addUserActionBreadcrumb(String action, {Map<String, String>? data}) {
    _ensureInitialized();
    _breadcrumbManager.addUserAction(action, data: data);
  }

  /// Add system event breadcrumb
  void addSystemBreadcrumb(String event, {BreadcrumbLevel level = BreadcrumbLevel.info, Map<String, String>? data}) {
    _ensureInitialized();
    _breadcrumbManager.addSystemEvent(event, level: level, data: data);
  }

  /// Add network event breadcrumb
  void addNetworkBreadcrumb(String event, {BreadcrumbLevel level = BreadcrumbLevel.info, Map<String, String>? data}) {
    _ensureInitialized();
    _breadcrumbManager.addNetworkEvent(event, level: level, data: data);
  }

  /// Add UI event breadcrumb
  void addUIBreadcrumb(String event, {Map<String, String>? data}) {
    _ensureInitialized();
    _breadcrumbManager.addUIEvent(event, data: data);
  }

  /// Add custom breadcrumb
  void addCustomBreadcrumb(String message, {BreadcrumbLevel level = BreadcrumbLevel.info, Map<String, String>? data}) {
    _ensureInitialized();
    _breadcrumbManager.addCustom(message, level: level, data: data);
  }

  /// Get all breadcrumbs
  List<Breadcrumb> getBreadcrumbs() {
    _ensureInitialized();
    return _breadcrumbManager.getBreadcrumbs();
  }

  /// Clear all breadcrumbs
  void clearBreadcrumbs() {
    _ensureInitialized();
    _breadcrumbManager.clear();
  }

  // ==================== REPORT API METHODS ====================

  /// Generate a summary report of recent activity
  Future<GeneratedReport> generateSummaryReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    _ensureReportingEnabled();
    return await _reportGenerator!.generateSummaryReport(
      startTime: startTime,
      endTime: endTime,
      title: title,
    );
  }

  /// Generate a detailed performance report
  Future<GeneratedReport> generatePerformanceReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    _ensureReportingEnabled();
    return await _reportGenerator!.generatePerformanceReport(
      startTime: startTime,
      endTime: endTime,
      title: title,
    );
  }

  /// Generate a user behavior analysis report
  Future<GeneratedReport> generateUserBehaviorReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    _ensureReportingEnabled();
    return await _reportGenerator!.generateUserBehaviorReport(
      startTime: startTime,
      endTime: endTime,
      title: title,
    );
  }

  /// Export report to file
  Future<String> exportReportToFile(
      GeneratedReport report, String filePath) async {
    _ensureReportingEnabled();

    String content;
    if (report.format == 'json') {
      content = report.toJson().toString();
    } else {
      content = report.data.toString();
    }

    final file = File(filePath);
    await file.writeAsString(content);
    return filePath;
  }

  /// Check if local reporting is enabled
  bool get isLocalReportingEnabled =>
      _reportStorage != null && _reportGenerator != null;

  /// Get current session information
  TelemetrySession? getCurrentSession() => _currentSession;

  // ==================== INTERNAL METHODS ====================

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

  /// Validate device ID format
  /// 
  /// Expected format: device_<timestamp>_<random>_<platform>
  /// Example: device_1704067200000_a8b9c2d1_android
  bool _isValidDeviceId(String deviceId) {
    try {
      // Expected format: device_<timestamp>_<random>_<platform>
      final regex = RegExp(r'^device_\d{13}_[a-z0-9]{8}_(android|ios|web|windows|macos|linux|fuchsia|unknown)$');
      return regex.hasMatch(deviceId);
    } catch (e) {
      if (_config?.debugMode == true) {
        print('⚠️ Device ID validation error: $e');
      }
      return false;
    }
  }

  /// Dispose all resources (call when app is shutting down)
  void dispose() {
    // End session before disposing
    _sessionManager.endSession();

    // End current session if reporting is enabled
    if (isLocalReportingEnabled && _currentSessionId != null) {
      _currentSession = _currentSession?.copyWith(endTime: DateTime.now());
      _reportStorage?.endSession(_currentSessionId!).catchError((e) {
        if (_config?.debugMode == true) {
          print('⚠️ Failed to end session: $e');
        }
      });
    }

    // Remove HTTP monitoring
    if (_httpMonitoringInstalled) {
      TelemetryHttpOverrides.uninstallGlobal();
      _httpMonitoringInstalled = false;
    }

    // Dispose reporting components
    _reportStorage?.dispose();

    // Existing cleanup
    _networkSubscription?.cancel();
    _networkMonitor?.dispose();
    _performanceMonitor?.dispose();
    _navigationObserver.dispose();
    _initialized = false;

    if (_config?.debugMode == true) {
      print('🧹 EdgeTelemetry disposed');
      print('🌐 HTTP monitoring removed');
    }
  }
}
