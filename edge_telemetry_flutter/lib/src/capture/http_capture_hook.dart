// lib/src/capture/http_capture_hook.dart

import '../core/edge_event.dart';
import '../core/models/breadcrumb.dart';
import '../managers/breadcrumb_manager.dart';
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

  /// Crash-context ring: each completed request drops a sanitized-path
  /// breadcrumb (path only — never the query string, which can carry PII).
  final BreadcrumbManager? breadcrumbs;

  bool _installed = false;

  HttpCaptureHook({this.debugMode = false, this.breadcrumbs});

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

    // Sanitized path only — drop query/fragment so no PII rides the ring.
    final path = Uri.tryParse(t.url)?.path ?? t.url;
    breadcrumbs?.addNetworkEvent(
      '${t.method} $path',
      level: t.isSuccess ? BreadcrumbLevel.info : BreadcrumbLevel.error,
      data: {
        'path': path,
        'method': t.method,
        'status': t.statusCode.toString(),
      },
    );
  }
}
