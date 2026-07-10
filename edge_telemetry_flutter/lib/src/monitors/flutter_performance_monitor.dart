// lib/src/monitors/flutter_performance_monitor.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/interfaces/event_tracker.dart';
import '../core/interfaces/performance_monitor.dart';

/// Flutter implementation of performance monitoring
///
/// Tracks frame rendering, memory usage, app startup time,
/// and other performance metrics using Flutter's built-in tools
class FlutterPerformanceMonitor implements PerformanceMonitor {
  DateTime? _appStartTime;
  Timer? _performanceTimer;
  Timer? _memoryTimer;

  final EventTracker? _eventTracker;
  bool _isInitialized = false;

  FlutterPerformanceMonitor({EventTracker? eventTracker})
      : _eventTracker = eventTracker;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    _appStartTime = DateTime.now();

    // Monitor frame performance
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);

    // Track app startup after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      trackAppStartup();
    });

    // Start periodic performance monitoring
    _startPeriodicMonitoring();

    _isInitialized = true;

    _eventTracker?.trackEvent('performance.monitor_initialized', attributes: {
      'monitor.type': 'flutter_performance_monitor',
      'monitoring.frame_timing': 'true',
      'monitoring.memory': 'true',
      'monitoring.system': 'true',
    });
  }

  @override
  void dispose() {
    _performanceTimer?.cancel();
    _memoryTimer?.cancel();
    _isInitialized = false;
  }

  @override
  void trackAppStartup() {
    if (_appStartTime == null) return;

    final startupDuration = DateTime.now().difference(_appStartTime!);
    final startupMs = startupDuration.inMilliseconds;

    // Determine startup type based on duration
    final startupType = _determineStartupType(startupMs);

    _eventTracker?.trackEvent('performance.app_startup', attributes: {
      'startup.duration_ms': startupMs.toString(),
      'startup.type': startupType,
      'startup.timestamp': DateTime.now().toIso8601String(),
      'startup.first_frame': 'true',
    });

    _eventTracker?.trackMetric('performance.startup_time', startupMs.toDouble(),
        attributes: {
          'startup.type': startupType,
          'metric.unit': 'milliseconds',
        });
  }

  @override
  void trackFrameTiming(FrameTiming timing) {
    final buildDuration =
        timing.buildDuration.inMicroseconds / 1000; // Convert to ms
    final rasterDuration =
        timing.rasterDuration.inMicroseconds / 1000; // Convert to ms
    final totalDuration = buildDuration + rasterDuration;

    // Determine frame quality
    final frameType = _determineFrameType(totalDuration);
    final isDropped = totalDuration > 16.67; // 60fps threshold

    // Track frame metrics
    _eventTracker
        ?.trackMetric('performance.frame_time', totalDuration, attributes: {
      'frame.build_duration_ms': buildDuration.toString(),
      'frame.raster_duration_ms': rasterDuration.toString(),
      'frame.type': frameType,
      'frame.dropped': isDropped.toString(),
      'metric.unit': 'milliseconds',
    });

    // Track dropped frames specifically
    if (isDropped) {
      final severity =
          totalDuration > 33.33 ? 'severe' : 'minor'; // 30fps threshold

      _eventTracker?.trackEvent('performance.frame_drop', attributes: {
        'frame.build_duration_ms': buildDuration.toString(),
        'frame.raster_duration_ms': rasterDuration.toString(),
        'frame.total_duration_ms': totalDuration.toString(),
        'frame.severity': severity,
        'frame.target_fps': '60',
      });
    }
  }

  @override
  void trackMemoryUsage() {
    try {
      final memoryUsage = _getMemoryUsage();
      if (memoryUsage != null) {
        _eventTracker?.trackMetric(
            'performance.memory_usage', memoryUsage.toDouble(),
            attributes: {
              'memory.type': 'rss',
              'memory.unit': 'bytes',
              'memory.source': 'process_info',
            });

        // Track memory pressure if usage is high
        _trackMemoryPressure(memoryUsage);
      }
    } catch (e) {
      _eventTracker?.trackError(e, attributes: {
        'error.context': 'memory_usage_tracking',
        'error.component': 'performance_monitor',
      });
    }
  }

  @override
  void trackSystemPerformance() {
    final systemInfo = _getSystemPerformanceInfo();

    _eventTracker?.trackEvent('performance.system_check', attributes: {
      'system.timestamp': DateTime.now().toIso8601String(),
      'system.check_type': 'periodic',
      'system.platform': systemInfo['platform'] ?? 'unknown',
      ...systemInfo,
    });
  }

  /// Start periodic monitoring timers
  void _startPeriodicMonitoring() {
    // System performance check every 30 seconds
    _performanceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      trackSystemPerformance();
    });

    // Memory usage check every 10 seconds
    _memoryTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      trackMemoryUsage();
    });
  }

  /// Handle frame timing callbacks from Flutter
  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      trackFrameTiming(timing);
    }
  }

  /// Determine startup type based on duration
  String _determineStartupType(int durationMs) {
    if (durationMs < 1000) return 'hot_start';
    if (durationMs < 3000) return 'warm_start';
    return 'cold_start';
  }

  /// Determine frame type based on duration
  String _determineFrameType(double durationMs) {
    if (durationMs <= 16.67) return 'smooth';
    if (durationMs <= 33.33) return 'janky';
    return 'severely_dropped';
  }

  /// Get current memory usage in bytes
  int? _getMemoryUsage() {
    try {
      return ProcessInfo.currentRss;
    } catch (e) {
      // Memory info not available on all platforms
      return null;
    }
  }

  /// Track memory pressure events
  void _trackMemoryPressure(int memoryBytes) {
    final memoryMB = memoryBytes / (1024 * 1024);

    String pressureLevel;
    if (memoryMB > 500) {
      pressureLevel = 'critical';
    } else if (memoryMB > 300) {
      pressureLevel = 'high';
    } else if (memoryMB > 150) {
      pressureLevel = 'moderate';
    } else {
      pressureLevel = 'normal';
    }

    if (pressureLevel != 'normal') {
      _eventTracker?.trackEvent('performance.memory_pressure', attributes: {
        'memory.usage_mb': memoryMB.toStringAsFixed(2),
        'memory.pressure_level': pressureLevel,
        'memory.timestamp': DateTime.now().toIso8601String(),
      });
    }
  }

  /// Get system performance information
  Map<String, String> _getSystemPerformanceInfo() {
    final info = <String, String>{
      'platform': Platform.operatingSystem,
      'platform_version': Platform.operatingSystemVersion,
    };

    // Add memory info if available
    final memoryUsage = _getMemoryUsage();
    if (memoryUsage != null) {
      info['memory.current_rss'] = memoryUsage.toString();
      info['memory.current_mb'] =
          (memoryUsage / (1024 * 1024)).toStringAsFixed(2);
    }

    // Add processor info
    info['system.processor_count'] = Platform.numberOfProcessors.toString();

    return info;
  }
}
