// lib/src/capture/perf_capture_hook.dart

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/edge_event.dart';
import 'capture_hook.dart';

/// Frame timing and startup capture. `dispose` removes the frame-timing
/// callback (no leak across restarts).
///
/// **Timer-free since v3 (#91).** v2 also ran two `Timer.periodic`s here — a
/// 10-second memory sample (`memory_usage` + an off-cadence
/// `performance.memory_pressure`) and a 30-second `performance.system_check` —
/// roughly 58 items per session into a time series with no named consumer, two
/// of whose three names the canon allowlist dropped on every device anyway.
/// Health is no longer a time series: memory rides the two session bookends
/// (`MemoryBookendHook`) and the fault bundle rides fatal crashes only. Nothing
/// here polls, which also means nothing here has to be cancelled on pause.
class PerfCaptureHook implements CaptureHook {
  DateTime? _appStartTime;
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

    return () {
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
}
