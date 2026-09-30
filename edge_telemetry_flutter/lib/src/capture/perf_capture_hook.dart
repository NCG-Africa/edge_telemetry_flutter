// lib/src/capture/perf_capture_hook.dart

import 'package:flutter/material.dart';

import '../core/edge_event.dart';
import 'capture_hook.dart';

/// App-startup capture — one `page_load` event and one `performance.startup_time`
/// metric per launch, nothing else.
///
/// **Two things left this hook in v3 and neither is coming back.** Frames went to
/// [FrameCaptureHook] behind `Capture.frames` (#89), because `Capture.frames:
/// false` has to take the `addTimingsCallback` registration with it — the
/// per-frame cost then goes to literally zero rather than to "accumulate and
/// discard". Health stopped being a time series (#91): v2 ran two
/// `Timer.periodic`s here — a 10-second memory sample (`memory_usage` plus an
/// off-cadence `performance.memory_pressure`) and a 30-second
/// `performance.system_check` — roughly 58 items per session into a time series
/// with no named consumer, two of whose three names the canon allowlist dropped
/// on every device anyway. Memory now rides the two session bookends
/// ([MemoryBookendHook]) and the fault bundle rides fatal crashes only.
///
/// Nothing here polls and nothing here registers a frame callback, so there is
/// no timer to cancel, no callback to remove, and nothing to do on pause.
class PerfCaptureHook implements CaptureHook {
  DateTime? _appStartTime;

  @override
  DisposeHandle start(EventSink sink) {
    _appStartTime = DateTime.now();

    WidgetsBinding.instance.addPostFrameCallback((_) => _trackAppStartup(sink));

    return () {};
  }

  void _trackAppStartup(EventSink sink) {
    if (_appStartTime == null) return;
    final startupMs = DateTime.now().difference(_appStartTime!).inMilliseconds;
    final startupType = _determineStartupType(startupMs);

    sink.add(
      EdgeEvent.event(
        'page_load',
        attributes: {
          'startup.type': startupType,
          // SDK-init-relative (undercounts anything before initialize()); documented
          // caveat in README. Measured from hook start → first post-frame callback.
          'startup.time_to_first_frame_ms': startupMs.toString(),
          // Kept for backward-compat (== time_to_first_frame_ms); the split is
          // purely additive — no existing key dropped.
          'startup.duration_ms': startupMs.toString(),
          'startup.timestamp': DateTime.now().toIso8601String(),
          'startup.first_frame': 'true',
        },
      ),
    );
    sink.add(
      EdgeEvent.metric(
        'performance.startup_time',
        startupMs.toDouble(),
        attributes: {
          'startup.type': startupType,
          'metric.unit': 'milliseconds',
        },
      ),
    );
  }

  // Canon startup taxonomy is cold | warm (glossary §4). This hook only runs at
  // SDK init, so it can't truly see a warm (already-resident) start; a duration
  // threshold is the passive Dart-side proxy.
  // ponytail: threshold heuristic; true cold/warm needs the native engine-init
  // timeline (deferred to the native-crash ticket #10).
  String _determineStartupType(int durationMs) =>
      durationMs < 2000 ? 'warm' : 'cold';
}
