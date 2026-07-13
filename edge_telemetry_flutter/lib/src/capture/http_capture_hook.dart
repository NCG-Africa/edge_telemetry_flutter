// lib/src/capture/http_capture_hook.dart

import '../core/edge_event.dart';
import 'capture_hook.dart';
import 'http_overrides.dart';

/// Captures every HTTP request by installing [TelemetryHttpOverrides] globally
/// and folding each completed request into a single canon `http.request` event
/// (status/duration/success/error all ride in its attributes).
///
/// `dispose` restores the prior `HttpOverrides.global`, so nothing leaks across
/// hot-restarts.
class HttpCaptureHook implements CaptureHook {
  final bool debugMode;
  bool _installed = false;

  HttpCaptureHook({this.debugMode = false});

  @override
  DisposeHandle start(EventSink sink) {
    if (!_installed) {
      TelemetryHttpOverrides.installGlobal(
        onRequestComplete: (t) => _emit(sink, t),
        debugMode: debugMode,
      );
      _installed = true;
    }
    return () {
      if (_installed) {
        TelemetryHttpOverrides.uninstallGlobal();
        _installed = false;
      }
    };
  }

  /// Canon: every request completes as a single `http.request` (mapping §2 —
  /// the old `http.error` / `http.slow_request` / `http.response_time` fold in
  /// here; `t.toAttributes()` already carries status, duration, success, and any
  /// error). Bumps session counters, as the HTTP path did in v1.5.2.
  void _emit(EventSink sink, HttpRequestTelemetry t) {
    sink.add(EdgeEvent.event('http.request',
        attributes: t.toAttributes(), countsToSession: true));
  }
}
