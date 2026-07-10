// lib/src/core/interfaces/network_monitor.dart

import 'telemetry_monitor.dart';

/// Interface for monitoring network connectivity and quality
///
/// Implementations should track:
/// - Network type changes (WiFi, mobile, none)
/// - Connection quality and speed
/// - Network availability events
abstract class NetworkMonitor extends TelemetryMonitor {
  /// Get the current network type (wifi, mobile, none, etc.)
  String get currentNetworkType;

  /// Stream of network type changes
  ///
  /// Emits new network type whenever connectivity changes
  Stream<String> get networkTypeChanges;

  /// Get network quality score (0.0 to 5.0)
  ///
  /// - 5.0: Excellent (Ethernet)
  /// - 4.0: High (WiFi)
  /// - 3.0: Good (Mobile)
  /// - 2.0: Fair (Unknown)
  /// - 1.0: Poor
  /// - 0.0: No connection
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
}
