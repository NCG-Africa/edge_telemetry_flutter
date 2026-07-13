// lib/src/capture/perf_capture_hook.dart

import 'dart:async' show Timer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/edge_event.dart';
import 'capture_hook.dart';

/// Frame timing, memory, and startup capture. Ports v1.5.2
/// `FlutterPerformanceMonitor` verbatim onto the [EventSink] seam — same event
/// and metric names, sent direct (no session-counter bump). `dispose` cancels
/// the timers and removes the frame-timing callback (no leak across restarts).
class PerfCaptureHook implements CaptureHook {
  DateTime? _appStartTime;
  Timer? _performanceTimer;
  Timer? _memoryTimer;
  TimingsCallback? _timingsCallback;

  @override
  DisposeHandle start(EventSink sink) {
    _appStartTime = DateTime.now();

    _timingsCallback = (timings) {
      for (final timing in timings) {
        _trackFrameTiming(sink, timing);
      }
    };
    WidgetsBinding.instance.addTimingsCallback(_timingsCallback!);
    WidgetsBinding.instance.addPostFrameCallback((_) => _trackAppStartup(sink));

    _performanceTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _trackSystemPerformance(sink));
    _memoryTimer = Timer.periodic(
        const Duration(seconds: 10), (_) => _trackMemoryUsage(sink));

    sink.add(
        const EdgeEvent.event('performance.monitor_initialized', attributes: {
      'monitor.type': 'flutter_performance_monitor',
      'monitoring.frame_timing': 'true',
      'monitoring.memory': 'true',
      'monitoring.system': 'true',
    }));

    return () {
      _performanceTimer?.cancel();
      _memoryTimer?.cancel();
      if (_timingsCallback != null) {
        WidgetsBinding.instance.removeTimingsCallback(_timingsCallback!);
        _timingsCallback = null;
      }
    };
  }

  void _trackAppStartup(EventSink sink) {
    if (_appStartTime == null) return;
    final startupMs = DateTime.now().difference(_appStartTime!).inMilliseconds;
    final startupType = _determineStartupType(startupMs);

    sink.add(EdgeEvent.event('page_load', attributes: {
      'startup.type': startupType,
      // SDK-init-relative (undercounts anything before initialize()); documented
      // caveat in README. Measured from hook start → first post-frame callback.
      'startup.time_to_first_frame_ms': startupMs.toString(),
      // Kept for backward-compat (== time_to_first_frame_ms); the split is
      // purely additive — no existing key dropped.
      'startup.duration_ms': startupMs.toString(),
      'startup.timestamp': DateTime.now().toIso8601String(),
      'startup.first_frame': 'true',
    }));
    sink.add(EdgeEvent.metric('performance.startup_time', startupMs.toDouble(),
        attributes: {
          'startup.type': startupType,
          'metric.unit': 'milliseconds',
        }));
  }

  void _trackFrameTiming(EventSink sink, FrameTiming timing) {
    final buildDuration = timing.buildDuration.inMicroseconds / 1000;
    final rasterDuration = timing.rasterDuration.inMicroseconds / 1000;
    final totalDuration = buildDuration + rasterDuration;
    final frameType = _determineFrameType(totalDuration);
    final isDropped = totalDuration > 16.67;

    sink.add(EdgeEvent.metric('frame_render_time', totalDuration, attributes: {
      // Canon split (glossary §1, dotless metric internals): UI-thread build vs
      // GPU raster — the whole jank-triage decision the single total can't make.
      'build_time_ms': buildDuration.toString(),
      'raster_time_ms': rasterDuration.toString(),
      'frame.type': frameType,
      'frame.dropped': isDropped.toString(),
      'metric.unit': 'milliseconds',
    }));

    if (isDropped) {
      final severity = totalDuration > 33.33 ? 'severe' : 'minor';
      // Canon: a dropped frame is the `long_task` metric (event→metric, §4).
      sink.add(EdgeEvent.metric('long_task', totalDuration, attributes: {
        'frame.build_duration_ms': buildDuration.toString(),
        'frame.raster_duration_ms': rasterDuration.toString(),
        'frame.total_duration_ms': totalDuration.toString(),
        'frame.severity': severity,
        'frame.target_fps': '60',
      }));
    }
  }

  void _trackMemoryUsage(EventSink sink) {
    try {
      final memoryUsage = _getMemoryUsage();
      if (memoryUsage != null) {
        sink.add(EdgeEvent.metric('memory_usage', memoryUsage.toDouble(),
            attributes: {
              'memory.type': 'rss',
              'memory.unit': 'bytes',
              'memory.source': 'process_info',
            }));
        _trackMemoryPressure(sink, memoryUsage);
      }
    } catch (e) {
      sink.add(EdgeEvent.error(e, attributes: {
        'error.context': 'memory_usage_tracking',
        'error.component': 'performance_monitor',
      }));
    }
  }

  void _trackSystemPerformance(EventSink sink) {
    final systemInfo = _getSystemPerformanceInfo();
    sink.add(EdgeEvent.event('performance.system_check', attributes: {
      'system.timestamp': DateTime.now().toIso8601String(),
      'system.check_type': 'periodic',
      'system.platform': systemInfo['platform'] ?? 'unknown',
      ...systemInfo,
    }));
  }

  // Canon startup taxonomy is cold | warm (glossary §4). This hook only runs at
  // SDK init, so it can't truly see a warm (already-resident) start; a duration
  // threshold is the passive Dart-side proxy.
  // ponytail: threshold heuristic; true cold/warm needs the native engine-init
  // timeline (deferred to the native-crash ticket #10).
  String _determineStartupType(int durationMs) =>
      durationMs < 2000 ? 'warm' : 'cold';

  String _determineFrameType(double durationMs) {
    if (durationMs <= 16.67) return 'smooth';
    if (durationMs <= 33.33) return 'janky';
    return 'severely_dropped';
  }

  int? _getMemoryUsage() {
    try {
      return ProcessInfo.currentRss;
    } catch (e) {
      return null;
    }
  }

  void _trackMemoryPressure(EventSink sink, int memoryBytes) {
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
      sink.add(EdgeEvent.event('performance.memory_pressure', attributes: {
        'memory.usage_mb': memoryMB.toStringAsFixed(2),
        'memory.pressure_level': pressureLevel,
        'memory.timestamp': DateTime.now().toIso8601String(),
      }));
    }
  }

  Map<String, String> _getSystemPerformanceInfo() {
    final info = <String, String>{
      'platform': Platform.operatingSystem,
      'platform_version': Platform.operatingSystemVersion,
    };
    final memoryUsage = _getMemoryUsage();
    if (memoryUsage != null) {
      info['memory.current_rss'] = memoryUsage.toString();
      info['memory.current_mb'] =
          (memoryUsage / (1024 * 1024)).toStringAsFixed(2);
    }
    info['system.processor_count'] = Platform.numberOfProcessors.toString();
    return info;
  }
}
