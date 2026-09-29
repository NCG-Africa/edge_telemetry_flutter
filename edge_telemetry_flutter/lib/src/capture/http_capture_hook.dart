// lib/src/capture/http_capture_hook.dart

import '../core/capture_gate.dart';
import '../core/config/collection_tier.dart';
import '../core/edge_event.dart';
import '../core/models/breadcrumb.dart';
import '../managers/breadcrumb_manager.dart';
import 'capture_hook.dart';
import 'http_overrides.dart';
import 'http_url.dart';

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

  /// The two `diagnostic` switches this hook reads. Optional so a faked hook
  /// can run without one, in which case both are off.
  final CaptureGate? gate;

  /// Resolved **once, at install** rather than per emission.
  ///
  /// One of them has to be: the DNS split changes how the socket is made, so
  /// it is decided before any request exists. The other follows it on purpose
  /// — a URL policy that flipped mid-session would make one column mean two
  /// different things inside one session, which is the invisible-meaning-drift
  /// §8 rejects everywhere else.
  bool _fullUrl = false;
  bool _phases = false;

  bool _installed = false;

  HttpCaptureHook({this.debugMode = false, this.breadcrumbs, this.gate});

  @override
  DisposeHandle start(EventSink sink) {
    if (!_installed) {
      _fullUrl = gate?.allows(Capture.httpQueryString) ?? false;
      _phases = gate?.allows(Capture.httpPhaseTiming) ?? false;
      TelemetryHttpOverrides.installGlobal(
        onRequestComplete: (t) => _emit(sink, t),
        debugMode: debugMode,
        measurePhases: _phases,
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
  /// here). Bumps session counters, as the HTTP path did in v1.5.2.
  void _emit(EventSink sink, HttpRequestTelemetry t) {
    sink.add(EdgeEvent.event('http.request',
        attributes: t.toAttributes(fullUrl: _fullUrl, phases: _phases),
        countsToSession: true));

    // Templated path only — no query, no fragment, no raw ids, so neither PII
    // nor unbounded cardinality rides the ring.
    final path = templatePath(Uri.tryParse(t.url)?.path ?? t.url);
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
