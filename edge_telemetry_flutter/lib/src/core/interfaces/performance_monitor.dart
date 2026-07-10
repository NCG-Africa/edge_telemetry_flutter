// lib/src/core/interfaces/performance_monitor.dart

import 'package:flutter/scheduler.dart';

import 'telemetry_monitor.dart';

/// Interface for monitoring app performance metrics
///
/// Implementations should track:
/// - Frame rendering performance
/// - App startup time
/// - Memory usage
/// - System performance metrics
abstract class PerformanceMonitor extends TelemetryMonitor {
  /// Track app startup performance
  ///
  /// Should be called when the app has finished loading
  /// to measure cold/warm/hot start times
  void trackAppStartup();

  /// Track individual frame rendering performance
  ///
  /// Called for each frame to detect dropped frames
  /// and measure build/raster durations
  void trackFrameTiming(FrameTiming timing);

  /// Track memory usage patterns
  ///
  /// Should periodically report memory consumption
  /// to detect memory leaks and pressure
  void trackMemoryUsage();

  /// Track system performance metrics
  ///
  /// Should collect general system health indicators
  /// like CPU usage, thermal state, etc.
  void trackSystemPerformance();
}
