// lib/src/capture/network_capture_hook.dart

import 'dart:async' show StreamSubscription;

import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/edge_event.dart';
import '../managers/context_manager.dart';
import 'capture_hook.dart';

/// Connectivity capture. Ports v1.5.2 `FlutterNetworkMonitor` onto the
/// [EventSink] seam — same `network.monitor_initialized` /
/// `network.connectivity_change` events and `network.quality_score` metric
/// (sent direct, no counter bump) — and folds the live `network.type` into the
/// [ContextManager] (the source `snapshot()` reads).
class NetworkCaptureHook implements CaptureHook {
  final ContextManager context;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  String _currentNetworkType = 'unknown';

  NetworkCaptureHook({required this.context});

  String get currentNetworkType => _currentNetworkType;

  @override
  DisposeHandle start(EventSink sink) {
    _init(sink);
    return () => _subscription?.cancel();
  }

  Future<void> _init(EventSink sink) async {
    try {
      _handleConnectivityChange(sink, await _connectivity.checkConnectivity());
      _subscription = _connectivity.onConnectivityChanged
          .listen((results) => _handleConnectivityChange(sink, results));

      sink.add(EdgeEvent.event('network.monitor_initialized', attributes: {
        'initial_network_type': _currentNetworkType,
        'monitor.type': 'flutter_connectivity_plus',
      }));
    } catch (e) {
      sink.add(EdgeEvent.error(e, attributes: {
        'error.context': 'network_monitor_initialization',
        'error.component': 'flutter_network_monitor',
      }));
    }
  }

  void _handleConnectivityChange(
      EventSink sink, List<ConnectivityResult> results) {
    final primary =
        results.isNotEmpty ? results.first : ConnectivityResult.none;
    final newType = _mapConnectivityResult(primary);
    if (newType == _currentNetworkType) return;

    final previous = _currentNetworkType;
    _currentNetworkType = newType;
    context.networkType = newType;

    sink.add(EdgeEvent.event('network.connectivity_change', attributes: {
      'network.previous_type': previous,
      'network.current_type': newType,
      'network.change_timestamp': DateTime.now().toIso8601String(),
      'network.available': newType != 'none' ? 'true' : 'false',
      'network.change_direction': _getChangeDirection(previous, newType),
    }));

    final qualityScore = getNetworkQualityScore(newType);
    sink.add(
        EdgeEvent.metric('network.quality_score', qualityScore, attributes: {
      'network.type': newType,
      'network.quality_level': _getNetworkQualityLevel(qualityScore),
      'metric.source': 'connectivity_estimation',
    }));
  }

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

  String _getChangeDirection(String previous, String next) {
    if (previous == 'none' && next != 'none') return 'connected';
    if (previous != 'none' && next == 'none') return 'disconnected';
    if (previous != next) return 'switched';
    return 'unchanged';
  }

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

  String _getNetworkQualityLevel(double score) {
    if (score >= 4.0) return 'excellent';
    if (score >= 3.0) return 'good';
    if (score >= 2.0) return 'fair';
    if (score >= 1.0) return 'poor';
    return 'none';
  }

  bool get isNetworkAvailable => _currentNetworkType != 'none';

  Map<String, String> getConnectivityInfo() => {
        'network.type': _currentNetworkType,
        'network.available': isNetworkAvailable.toString(),
        'network.quality_score':
            getNetworkQualityScore(_currentNetworkType).toString(),
        'network.quality_level': _getNetworkQualityLevel(
            getNetworkQualityScore(_currentNetworkType)),
        'network.last_check': DateTime.now().toIso8601String(),
      };
}
