// lib/src/capture/http_capture_hook.dart

import 'package:http/http.dart' as http;

import '../core/capture_gate.dart';
import '../core/config/collection_tier.dart';
import '../core/edge_event.dart';
import '../core/models/breadcrumb.dart';
import '../managers/breadcrumb_manager.dart';
import 'capture_hook.dart';
import 'http_client_capture.dart';
import 'http_overrides.dart';
import 'http_url.dart';
import 'trace_injection.dart';

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

  /// The propagation half (#86). Optional so a faked hook runs un-traced.
  final TraceInjector? injector;

  /// `RetryTransport.resolvedUrl` — the SDK's own upload, excluded explicitly.
  final Uri? selfUrl;

  /// Resolved **once, at install** rather than per emission, so neither moves
  /// when the budget governor sheds the `diagnostic` tier mid-session.
  ///
  /// One of them has to be fixed: the DNS split changes how the socket is
  /// made, and a shed cannot un-measure a connection that already happened.
  /// The URL policy follows it on purpose — a column that meant the full URL
  /// for the first 250 items and the path for the rest would be the
  /// invisible-meaning-drift §8 rejects everywhere else. Shedding is about
  /// *items*, and these are fields on an item the shed already decided to
  /// keep.
  bool _fullUrl = false;
  bool _phases = false;

  bool _installed = false;

  /// Held from [start] so [capture] can emit down the same path the global
  /// override does — one `_emit`, so both seams produce the same row shape,
  /// the same breadcrumb and the same tier switches.
  EventSink? _sink;

  HttpCaptureHook({
    this.debugMode = false,
    this.breadcrumbs,
    this.gate,
    this.injector,
    this.selfUrl,
  });

  @override
  DisposeHandle start(EventSink sink) {
    _sink = sink;
    if (!_installed) {
      _fullUrl = gate?.allows(Capture.httpQueryString) ?? false;
      _phases = gate?.allows(Capture.httpRequestPhases) ?? false;
      TelemetryHttpOverrides.installGlobal(
        onRequestComplete: (t) => _emit(sink, t),
        debugMode: debugMode,
        measurePhases: _phases,
        injector: injector,
        selfUrl: selfUrl,
      );
      _installed = true;
    }
    return () {
      if (_installed) {
        TelemetryHttpOverrides.uninstallGlobal();
        _installed = false;
      }
      _sink = null;
    };
  }

  /// Wrap one `package:http` client — the bypass half of §8 (#87).
  ///
  /// An already-captured client is returned **unchanged**, which is why the
  /// call returns the same type it takes: double capture is designed out at
  /// construction rather than documented around. So is a call made before
  /// [start] — with no sink there is nothing to emit into, and a wrapper that
  /// silently dropped rows would be worse than no wrapper.
  http.Client capture(http.Client client) {
    final sink = _sink;
    if (client is CapturedClient || sink == null) return client;
    markClientWrapped();
    return CapturedClient(
      inner: client,
      onRequestComplete: (t) => _emit(sink, t),
      injector: injector,
      selfUrl: selfUrl,
      debugMode: debugMode,
    );
  }

  /// Canon: every request completes as a single `http.request` (mapping §2 —
  /// the old `http.error` / `http.slow_request` / `http.response_time` fold in
  /// here). Bumps session counters, as the HTTP path did in v1.5.2.
  void _emit(EventSink sink, HttpRequestTelemetry t) {
    // `ownsTraceContext`: the request froze its trace context at the call
    // instant and this event is emitted at completion, hundreds of milliseconds
    // later. Without the strip the ambient snapshot would stamp whatever tap
    // landed mid-flight onto it — including onto the legally-unattributed rows,
    // where an absent key cannot beat a present one.
    sink.add(EdgeEvent.event('http.request',
        attributes: t.toAttributes(fullUrl: _fullUrl, phases: _phases),
        ownsTraceContext: true,
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
