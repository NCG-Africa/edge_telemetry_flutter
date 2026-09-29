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

  /// The client this one wraps — the escape hatch for a consumer who needs the
  /// original back, and what makes double-wrapping detectable at the facade.
  http.Client get inner => _inner;

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
          // Swallowed: the SDK must never be why a request fails. The ids stay
          // on the row and the outcome key comes off, because nothing was
          // propagated and absence is the contract's member for that.
          traceAttributes = Map<String, String>.from(traceAttributes)
            ..remove('traceparent.outcome');
        }
      }
    }

    final callStart = DateTime.now();
    final clock = Stopwatch()..start();

    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (error) {
      // Nothing came back at all. Same shape the `dart:io` seam reports for a
      // refused connection: ids so the row is correlatable, status 0, and the
      // time actually spent failing.
      //
      // **The outcome key comes off.** It was resolved before the send, but no
      // socket carried it — and absence is the contract's own member for "not
      // traced". A row claiming `injected_attributed` for a header that never
      // left the device would be the one lie the backend cannot detect.
      _onRequestComplete(HttpRequestTelemetry(
        url: request.url.toString(),
        method: request.method,
        statusCode: 0,
        duration: clock.elapsed,
        timestamp: callStart,
        error: error.toString(),
        traceAttributes: Map<String, String>.from(traceAttributes)
          ..remove('traceparent.outcome'),
        seam: kSeamHttpClient,
      ));
      rethrow;
    }

    // Headers received. The tail is the body, exactly as on the other seam.
    final atHeaders = clock.elapsed;
    return http.StreamedResponse(
      _countBody(response, callStart, clock, atHeaders, request.method,
          request.url, traceAttributes),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// Count the body and emit **when it ends**, not when its headers arrive:
  /// `http.download_ms` is the tail, and a byte count has no value until the
  /// last byte. The `finally` covers done, error and cancel alike, so a
  /// consumer who abandons a response still produces exactly one row.
  Stream<List<int>> _countBody(
    http.StreamedResponse response,
    DateTime callStart,
    Stopwatch clock,
    Duration atHeaders,
    String method,
    Uri url,
    Map<String, String> traceAttributes,
  ) async* {
    var bytes = 0;
    var complete = false;
    try {
      yield* response.stream.map((chunk) {
        bytes += chunk.length;
        return chunk;
      });
      complete = true;
    } finally {
      final declared = response.contentLength;
      // An unknown size is omitted, never a false zero: a body cancelled
      // part-way leaves a partial count, which is not the response size.
      final size = declared ?? (complete ? bytes : null);
      if (debugMode) {
        print('🌐 HTTP ${method.toUpperCase()} $url - ${response.statusCode} '
            '(${atHeaders.inMilliseconds}ms + '
            '${(clock.elapsed - atHeaders).inMilliseconds}ms body) [wrapper]');
      }
      _onRequestComplete(HttpRequestTelemetry(
        url: url.toString(),
        method: method,
        statusCode: response.statusCode,
        duration: atHeaders,
        timestamp: callStart,
        downloadDuration: clock.elapsed - atHeaders,
        responseSize: size,
        responseSizeSource: size == null
            ? null
            : declared != null
                ? kSizeFromContentLength
                : kSizeFromDecodedBytes,
        traceAttributes: traceAttributes,
        seam: kSeamHttpClient,
      ));
    }
  }

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
