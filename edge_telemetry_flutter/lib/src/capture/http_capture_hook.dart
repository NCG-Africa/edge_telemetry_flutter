// lib/src/capture/http_capture_hook.dart

import '../core/edge_event.dart';
import 'capture_hook.dart';
import 'http_overrides.dart';

/// Captures every HTTP request by installing [TelemetryHttpOverrides] globally
/// and folding each completed request into the same wire events as v1.5.2:
/// `http.request` (+ `http.response_time` metric, `http.error`, `http.slow_request`).
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

  /// Byte-identical to v1.5.2 `_trackHttpRequest`. These events flowed through
  /// the public API in v1.5.2, so they bump session counters.
  void _emit(EventSink sink, HttpRequestTelemetry t) {
    sink.add(EdgeEvent.event('http.request',
        attributes: t.toAttributes(), countsToSession: true));

    sink.add(EdgeEvent.metric(
      'http.response_time',
      t.duration.inMilliseconds.toDouble(),
      attributes: {
        'http.method': t.method,
        'http.status_code': t.statusCode.toString(),
        'http.category': t.category,
        'http.performance': t.performanceCategory,
      },
      countsToSession: true,
    ));

    if (!t.isSuccess) {
      sink.add(EdgeEvent.event('http.error',
          attributes: {
            ...t.toAttributes(),
            'error.type': 'http_error',
            'error.category': t.category,
          },
          countsToSession: true));
    }

    if (t.duration.inMilliseconds > 2000) {
      sink.add(EdgeEvent.event('http.slow_request',
          attributes: {
            ...t.toAttributes(),
            'performance.category': 'slow',
          },
          countsToSession: true));
    }
  }
}
