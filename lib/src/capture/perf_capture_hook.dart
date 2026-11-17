// lib/src/capture/perf_capture_hook.dart

import 'package:flutter/widgets.dart';

import '../core/edge_event.dart';
import '../crash/native_crash_channel.dart';
import 'capture_hook.dart';

/// App-startup capture — one `app.start` per process (catalogue `app_start.yaml`,
/// #127), nothing else.
///
/// t0 is **process start**, read natively (`processUptimeMs`), so the time
/// before `EdgeTelemetry.initialize()` is counted; the end is the first frame
/// after the SDK starts. `app.start.sdk_init_ms` is the cumulative offset of the
/// SDK's own start. Only `cold` is sent — the 2-second "warm" guess is gone.
///
/// Where the platform cannot say when the process started (no plugin, Android
/// below API 24) nothing is sent: an SDK-init-relative number under this name
/// would be the wrong quantity.
///
/// Nothing here polls and nothing here registers a frame callback, so there is
/// no timer to cancel, no callback to remove, and nothing to do on pause.
class PerfCaptureHook implements CaptureHook {
  PerfCaptureHook({required this.channel});

  final NativeCrashChannel channel;

  @override
  DisposeHandle start(EventSink sink) {
    final sdkStart = DateTime.now();
    // Asked now, while the uptime still describes this instant.
    final uptime = channel.processUptimeMs();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final firstFrame = DateTime.now();
      final sinceStart = await uptime;
      if (sinceStart == null) return;
      final processStart = sdkStart.subtract(
        Duration(milliseconds: sinceStart),
      );
      sink.add(
        EdgeEvent.event(
          'app.start',
          attributes: {
            'app.start.type': 'cold',
            'app.start.duration_ms':
                firstFrame.difference(processStart).inMilliseconds.toString(),
            'app.start.sdk_init_ms': sinceStart.toString(),
          },
          occurredAt: firstFrame,
        ),
      );
    });
    return () {};
  }
}
