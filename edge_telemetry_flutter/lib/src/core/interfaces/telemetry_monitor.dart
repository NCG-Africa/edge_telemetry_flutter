// lib/src/core/interfaces/telemetry_monitor.dart

/// Base interface for all telemetry monitors
///
/// All monitoring components (network, performance, etc.) implement this interface
/// to ensure consistent lifecycle management
abstract class TelemetryMonitor {
  /// Initialize the monitor and start collecting data
  Future<void> initialize();

  /// Clean up resources and stop monitoring
  void dispose();
}
