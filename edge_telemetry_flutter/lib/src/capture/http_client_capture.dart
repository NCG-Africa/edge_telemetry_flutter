// lib/src/capture/http_client_capture.dart
//
// The wrapper seam, §8's bypass half (#87). `HttpOverrides.global` reaches
// every `dart:io` socket and nothing else; roughly 7% of installs use a client
// that never touches one — `cupertino_http` (NSURLSession), `cronet_http`
// (Cronet) — and those apps are not *thinly* covered, they are **totally
// invisible**, so the consumer sees an empty dashboard rather than a short one.
//
// A doc-only answer died on tracing: the same seam carries `traceparent`, so an
// uncapturable request is a severed distributed trace. That is silent and far
// costlier than a missing row.
//
// Out of scope, and staying out: gRPC, HTTP/2 and `http2_adapter`. Those bypass
// `package:http` too — a protocol gap, not a wrapper gap, and a wrapper that
// pretended otherwise would be the coverage claim the seam-state key exists to
// refuse.

import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/screen_inflight.dart';
import 'http_overrides.dart';
import 'trace_injection.dart';

/// `http.seam` for a row this wrapper measured. Its absence of
/// `http.connect_ms` / `http.dns_ms` / `http.queue_ms` /
/// `http.connection_reused` is structural: the wrapper sits above the socket
/// and the platform client below it owns the connection pool.
const String kSeamHttpClient = 'http_client';

/// One captured `package:http` client: client in, client out.
///
/// Returning the *same type* is what designs double capture out rather than
/// documenting around it — see `EdgeTelemetry.captureClient`, which returns an
/// already-captured client unchanged because it can simply ask.
class CapturedClient extends http.BaseClient {
  CapturedClient({
    required http.Client inner,
    required void Function(HttpRequestTelemetry) onRequestComplete,
    this.injector,
    this.selfUrl,
    this.debugMode = false,
  })  : _inner = inner,
        _onRequestComplete = onRequestComplete;

  final http.Client _inner;
  final void Function(HttpRequestTelemetry) _onRequestComplete;

  /// The propagation half (#86). Null = no header and no trace keys.
  final TraceInjector? injector;

  /// The SDK's own upload target. A consumer who hands us the client their
  /// `RetryTransport` also uses would otherwise amplify without bound.
  final Uri? selfUrl;

  final bool debugMode;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_isSelfUpload(request.url)) return _inner.send(request);

    // **Freeze and inject are one instant here.** `send` is entered
    // synchronously from the consumer's call and `BaseRequest.headers` is still
    // mutable until the inner client finalizes it, so there is no await between
    // reading ambient trace context and writing the header it produced. The
    // `dart:io` seam has to freeze early and inject later — the base client's
    // `openUrl` awaits, measured at 509 ms cold — and pays for it with a
    // reachable [kOutcomeInjectedExpired]. On this seam that outcome is
    // **unreachable**: nothing can age out or rotate across zero awaits.
    final freeze = injector?.freeze() ?? (carrier: null, expired: false);
    var traceAttributes = const <String, String>{};
    final resolver = injector;
    if (resolver != null) {
      final decision = resolver.resolve(
        url: request.url,
        inbound: request.headers[kTraceparentHeader],
        freeze: freeze,
      );
      traceAttributes = decision.attributes;
      final header = decision.header;
      if (header != null) {
        try {
          request.headers[kTraceparentHeader] = header;
        } catch (_) {
          // An already-finalized request — the consumer is re-sending one.
          // Swallowed: the SDK must never be why a request fails.
          traceAttributes = _untraced(traceAttributes);
        }
      }
    }

    // The screen this request belongs to, claimed at the call instant for the
    // same reason the trace context is: the screen showing when it finishes is
    // not the screen that asked. Released on every completion path below.
    final screenId = beginScreenRequest();

    final callStart = DateTime.now();
    final clock = Stopwatch()..start();

    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (error) {
      // Nothing came back. Ids so the row is correlatable, status 0, and the
      // time actually spent failing.
      //
      // **The outcome key stays**, which is where this seam diverges from the
      // `dart:io` one — deliberately, because the fact differs. There, the
      // freeze happens before `openUrl` and a refused connection means the
      // header was never written at all, so absence is literally true. Here the
      // header is written onto the request *before* the send, unconditionally,
      // and nothing above `package:http` can see whether those bytes reached a
      // socket: `IOClient` finalizes the request before it even connects. So
      // the outcome reports what the SDK did — it injected — which is true on
      // every path through this seam. Guessing the socket's fate would make the
      // row claim a thing it cannot know, and a server span joined on this
      // `trace.id` would be orphaned by a wrong "not traced".
      endScreenRequest(screenId);
      _onRequestComplete(HttpRequestTelemetry(
        url: request.url.toString(),
        method: request.method,
        statusCode: 0,
        duration: clock.elapsed,
        timestamp: callStart,
        error: error.toString(),
        traceAttributes: traceAttributes,
        seam: kSeamHttpClient,
      ));
      rethrow;
    }

    // Headers received. The tail is the body, exactly as on the other seam.
    final atHeaders = clock.elapsed;
    var bytes = 0;
    var complete = false;

    /// Count the body and emit **when it ends**, not when its headers arrive:
    /// `http.download_ms` is the tail, and a byte count has no value until the
    /// last byte. The `finally` covers done, error and cancel alike, so a
    /// consumer who abandons a response still produces exactly one row.
    ///
    /// A local generator rather than a method: everything it needs is already
    /// in scope here, and threading the same seven values through a signature
    /// is what the `dart:io` seam needed a whole class for.
    Stream<List<int>> countBody() async* {
      try {
        yield* response.stream.map((chunk) {
          bytes += chunk.length;
          return chunk;
        });
        complete = true;
      } finally {
        final sized = resolveResponseSize(
          declared: response.contentLength,
          counted: bytes,
          complete: complete,
        );
        final download = clock.elapsed - atHeaders;
        if (debugMode) {
          print('🌐 HTTP ${request.method.toUpperCase()} ${request.url} - '
              '${response.statusCode} (${atHeaders.inMilliseconds}ms + '
              '${download.inMilliseconds}ms body) [$kSeamHttpClient]');
        }
        endScreenRequest(screenId);
        _onRequestComplete(HttpRequestTelemetry(
          url: request.url.toString(),
          method: request.method,
          statusCode: response.statusCode,
          duration: atHeaders,
          timestamp: callStart,
          downloadDuration: download,
          responseSize: sized.size,
          responseSizeSource: sized.source,
          traceAttributes: traceAttributes,
          seam: kSeamHttpClient,
        ));
      }
    }

    return http.StreamedResponse(
      countBody(),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// The same ids, minus the claim that anything was propagated. One helper so
  /// "absence is the contract's member for not traced" lives in one place.
  Map<String, String> _untraced(Map<String, String> attributes) =>
      Map<String, String>.from(attributes)..remove('traceparent.outcome');

  /// Same comparison the `dart:io` seam makes, for the same reason.
  bool _isSelfUpload(Uri url) {
    final self = selfUrl;
    return self != null &&
        url.scheme == self.scheme &&
        url.host == self.host &&
        url.port == self.port &&
        url.path == self.path;
  }

  @override
  void close() => _inner.close();
}
