// lib/src/monitors/flutter_network_monitor.dart

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/interfaces/event_tracker.dart';
import '../core/interfaces/network_monitor.dart';

/// Flutter implementation of network connectivity monitoring
///
/// Monitors network type changes and provides connectivity status
/// using the connectivity_plus plugin
class FlutterNetworkMonitor implements NetworkMonitor {
  late Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  String _currentNetworkType = 'unknown';

  final StreamController<String> _networkTypeController =
      StreamController<String>.broadcast();
  final EventTracker? _eventTracker;

  FlutterNetworkMonitor({EventTracker? eventTracker})
      : _eventTracker = eventTracker;

  @override
  String get currentNetworkType => _currentNetworkType;

  @override
  Stream<String> get networkTypeChanges => _networkTypeController.stream;

  @override
  Future<void> initialize() async {
    try {
      _connectivity = Connectivity();

      // Check initial connectivity
      final initialConnectivity = await _connectivity.checkConnectivity();
      _handleConnectivityChange(initialConnectivity);

      // Listen for connectivity changes
      _connectivitySubscription =
          _connectivity.onConnectivityChanged.listen(_handleConnectivityChange);

      // Track initialization
      _eventTracker?.trackEvent('network.monitor_initialized', attributes: {
        'initial_network_type': _currentNetworkType,
        'monitor.type': 'flutter_connectivity_plus',
      });
    } catch (e) {
      // Network monitoring not available, continue without it
      _eventTracker?.trackError(e, attributes: {
        'error.context': 'network_monitor_initialization',
        'error.component': 'flutter_network_monitor',
      });
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _networkTypeController.close();
  }

  /// Handle connectivity changes from the system
  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final primaryResult =
        results.isNotEmpty ? results.first : ConnectivityResult.none;

    final newNetworkType = _mapConnectivityResult(primaryResult);

    if (newNetworkType != _currentNetworkType) {
      final previousType = _currentNetworkType;
      _currentNetworkType = newNetworkType;

      // Emit the change
      _networkTypeController.add(newNetworkType);

      // Track the connectivity change
      _trackConnectivityChange(previousType, newNetworkType);

      // Track network quality
      _trackNetworkQuality(newNetworkType);
    }
  }

  /// Map ConnectivityResult to string representation
  String _mapConnectivityResult(ConnectivityResult result) {
    switch (result) {
      case ConnectivityResult.wifi:
        return 'wifi';
      case ConnectivityResult.mobile:
        return 'mobile';
      case ConnectivityResult.ethernet:
        return 'ethernet';
      case ConnectivityResult.bluetooth:
        return 'bluetooth';
      case ConnectivityResult.vpn:
        return 'vpn';
      case ConnectivityResult.none:
        return 'none';
      case ConnectivityResult.other:
        return 'other';
    }
  }

  /// Track connectivity change event
  void _trackConnectivityChange(String previousType, String newNetworkType) {
    _eventTracker?.trackEvent('network.connectivity_change', attributes: {
      'network.previous_type': previousType,
      'network.current_type': newNetworkType,
      'network.change_timestamp': DateTime.now().toIso8601String(),
      'network.available': newNetworkType != 'none' ? 'true' : 'false',
      'network.change_direction':
          _getChangeDirection(previousType, newNetworkType),
    });
  }

  /// Determine the direction of network change
  String _getChangeDirection(String previousType, String newNetworkType) {
    if (previousType == 'none' && newNetworkType != 'none') {
      return 'connected';
    } else if (previousType != 'none' && newNetworkType == 'none') {
      return 'disconnected';
    } else if (previousType != newNetworkType) {
      return 'switched';
    }
    return 'unchanged';
  }

  /// Track network quality metrics
  void _trackNetworkQuality(String networkType) {
    final qualityScore = getNetworkQualityScore(networkType);
    final qualityLevel = _getNetworkQualityLevel(qualityScore);

    _eventTracker
        ?.trackMetric('network.quality_score', qualityScore, attributes: {
      'network.type': networkType,
      'network.quality_level': qualityLevel,
      'metric.source': 'connectivity_estimation',
    });
  }

  /// Convert quality score to descriptive level
  String _getNetworkQualityLevel(double score) {
    if (score >= 4.0) return 'excellent';
    if (score >= 3.0) return 'good';
    if (score >= 2.0) return 'fair';
    if (score >= 1.0) return 'poor';
    return 'none';
  }

  @override
  double getNetworkQualityScore(String networkType) {
    switch (networkType) {
      case 'wifi':
        return 4.0;
      case 'mobile':
        return 3.0;
      case 'ethernet':
        return 5.0;
      case 'none':
        return 0.0;
      default:
        return 2.0;
    }
  }

  /// Check if network is currently available
  bool get isNetworkAvailable => _currentNetworkType != 'none';

  /// Get detailed connectivity information
  Map<String, String> getConnectivityInfo() {
    return {
      'network.type': _currentNetworkType,
      'network.available': isNetworkAvailable.toString(),
      'network.quality_score':
          getNetworkQualityScore(_currentNetworkType).toString(),
      'network.quality_level':
          _getNetworkQualityLevel(getNetworkQualityScore(_currentNetworkType)),
      'network.last_check': DateTime.now().toIso8601String(),
    };
  }
}
