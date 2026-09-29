// lib/src/capture/http_overrides.dart
//
// The `dart:io` seam: `HttpOverrides.global` wrappers plus the
// [HttpRequestTelemetry] data class. One of the two seams §8 names — the other
// is the wrapper seam (#87), which is why every request carries [kSeam].

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'http_url.dart';

/// Which seam captured a request. **Absence alone conflates "never measurable"
/// with "measurable and missing"** and leaves a backend's connect-time
/// denominator wrong, so the seam rides every row rather than being inferred
/// from which keys happen to be present.
const String kSeam = 'http_overrides';

/// HTTP overrides that automatically monitor all network requests
///
/// Wraps the default HttpClient to inject telemetry tracking
/// for every HTTP request made by the app
class TelemetryHttpOverrides extends HttpOverrides {
  final HttpOverrides? _previousOverrides;
  final Function(HttpRequestTelemetry) _onRequestComplete;
  final bool debugMode;

  /// Split DNS out of the fused connect number (`diagnostic` tier only).
  ///
  /// It costs a resolver call the platform does not experience and it connects
  /// to the **first** resolved address only, losing the platform's
  /// try-every-address fallback. That trade is exactly what fusing connect
  /// keeps out of every consumer's default build.
  final bool measurePhases;

  TelemetryHttpOverrides({
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
    this.measurePhases = false,
    HttpOverrides? previousOverrides,
  })  : _onRequestComplete = onRequestComplete,
        _previousOverrides = previousOverrides;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final baseClient = _previousOverrides?.createHttpClient(context) ??
        super.createHttpClient(context);

    return TelemetryHttpClient(
      baseClient: baseClient,
      onRequestComplete: _onRequestComplete,
      debugMode: debugMode,
      measurePhases: measurePhases,
      // Threaded by hand, and load-bearing — see [TelemetryHttpClient].
      securityContext: context,
    );
  }

  /// Install global HTTP monitoring
  static void installGlobal({
    required Function(HttpRequestTelemetry) onRequestComplete,
    bool debugMode = false,
    bool measurePhases = false,
  }) {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = TelemetryHttpOverrides(
      onRequestComplete: onRequestComplete,
      debugMode: debugMode,
      measurePhases: measurePhases,
      previousOverrides: previousOverrides,
    );
  }

  /// Remove global HTTP monitoring (restore previous overrides)
  static void uninstallGlobal() {
    if (HttpOverrides.current is TelemetryHttpOverrides) {
      final telemetryOverrides =
          HttpOverrides.current as TelemetryHttpOverrides;
      HttpOverrides.global = telemetryOverrides._previousOverrides;
    }
  }
}

/// One measured connection setup, keyed by the local port its socket bound to.
/// [claimed] is what makes the reuse flag *measured* rather than inferred: the
/// first request over a socket claims its record, every later request on the
/// same local port finds it claimed and is a reuse.
class HttpConnectRecord {
  HttpConnectRecord({required this.connectMs, this.dnsMs});

  final int connectMs;
  final int? dnsMs;
  bool claimed = false;
}

/// HTTP client wrapper that tracks all requests.
///
/// **It installs a connection factory**, which is how the fused connect time
/// and the measured reuse flag are reachable at all. That has a shipping
/// blocker attached: with a factory installed the platform takes a branch that
/// never reaches its own secure-socket call, so the [SecurityContext], the
/// bad-certificate callback and the TLS key log are **never applied unless
/// this class threads all three through by hand**. Certificate pinning would
/// otherwise break silently at init — the app keeps working, against any
/// certificate. Every one of the three is forwarded to the base client as
/// well, because the HTTPS-proxy tunnel path still runs inside the platform.
class TelemetryHttpClient implements HttpClient {
  final HttpClient _baseClient;
  final Function(HttpRequestTelemetry) _onRequestComplete;
  final bool debugMode;
  final bool measurePhases;

  /// The three values the platform stops applying the moment a connection
  /// factory exists.
  final SecurityContext? _securityContext;
  bool Function(X509Certificate, String, int)? _badCertificateCallback;
  Function(String)? _keyLog;

  /// A factory the consumer installed. Ours wraps it rather than replacing it,
  /// so their socket still gets made — and the pinning threading above stays
  /// theirs, exactly as it was before we existed.
  Future<ConnectionTask<Socket>> Function(Uri, String?, int?)?
      _consumerConnectionFactory;

  /// Live connections by local port. Bounded by the socket's own lifetime:
  /// each entry is removed when its socket closes.
  final Map<int, HttpConnectRecord> _connects = {};

  TelemetryHttpClient({
    required HttpClient baseClient,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
    this.measurePhases = false,
    SecurityContext? securityContext,
  })  : _baseClient = baseClient,
        _onRequestComplete = onRequestComplete,
        _securityContext = securityContext {
    _baseClient.connectionFactory = _connect;
  }

  /// Time one connection setup and record it against the local port.
  ///
  /// The number is **fused** — DNS + TCP + TLS in one — because splitting DNS
  /// means resolving by hand, and resolving by hand means connecting to one
  /// address instead of every address the platform would try. TCP and TLS
  /// cannot be separated here at all: the platform's `ConnectionTask` has no
  /// public constructor, so a factory cannot hand back a task wrapped around a
  /// socket it upgraded itself. Their sum is `connect - dns`; neither is
  /// guessed and neither is sent.
  ///
  /// Under an HTTPS proxy the socket we make is the plain one to the proxy and
  /// the TLS handshake happens inside the platform's CONNECT tunnel, so TLS
  /// time is unreachable at **any** tier and the fused number is proxy-connect
  /// only.
  Future<ConnectionTask<Socket>> _connect(
      Uri url, String? proxyHost, int? proxyPort) async {
    final start = DateTime.now();
    final consumer = _consumerConnectionFactory;

    int? dnsMs;
    ConnectionTask<Socket> task;

    if (consumer != null) {
      task = await consumer(url, proxyHost, proxyPort);
    } else {
      final host = proxyHost ?? url.host;
      final port = proxyPort ?? url.port;
      // Direct HTTPS is the only case where the factory owes a secured socket;
      // through a proxy the platform tunnels and secures it afterwards.
      final secure = proxyHost == null && url.scheme == 'https';

      Object connectHost = host;
      if (measurePhases) {
        final addresses = await InternetAddress.lookup(host);
        dnsMs = DateTime.now().difference(start).inMilliseconds;
        if (addresses.isNotEmpty) connectHost = addresses.first;
      }

      task = secure
          ? await SecureSocket.startConnect(
              connectHost,
              port,
              context: _securityContext,
              onBadCertificate: _badCertificateCallback == null
                  ? null
                  : (cert) => _badCertificateCallback!(cert, host, port),
              keyLog: _keyLog == null ? null : (line) => _keyLog!(line),
            )
          : await Socket.startConnect(connectHost, port);
    }

    unawaited(task.socket.then((socket) {
      final localPort = socket.port;
      _connects[localPort] = HttpConnectRecord(
        connectMs: DateTime.now().difference(start).inMilliseconds,
        dnsMs: dnsMs,
      );
      unawaited(socket.done
          .then((_) {}, onError: (_) {})
          .whenComplete(() => _connects.remove(localPort)));
    }, onError: (_) {}));

    return task;
  }

  // Forward all properties to base client
  @override
  Duration get connectionTimeout =>
      _baseClient.connectionTimeout ?? const Duration(seconds: 60);
  @override
  set connectionTimeout(Duration? value) =>
      _baseClient.connectionTimeout = value;

  @override
  Duration get idleTimeout => _baseClient.idleTimeout;
  @override
  set idleTimeout(Duration value) {
    _baseClient.idleTimeout = value;
  }

  @override
  int get maxConnectionsPerHost => _baseClient.maxConnectionsPerHost ?? 6;
  @override
  set maxConnectionsPerHost(int? value) =>
      _baseClient.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _baseClient.autoUncompress;
  @override
  set autoUncompress(bool value) => _baseClient.autoUncompress = value;

  @override
  String? get userAgent => _baseClient.userAgent;
  @override
  set userAgent(String? value) => _baseClient.userAgent = value;

  // Proxy all HTTP methods through our tracking wrapper. The clock starts
  // **before** the call, not after: `openUrl` is what establishes the
  // connection, so v2's post-`openUrl` start measured neither connection setup
  // nor content download and under-reported a cold request by 3.5-4x.
  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _track(method, Uri(scheme: 'http', host: host, port: port, path: path),
          () => _baseClient.open(method, host, port, path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _track(method, url, () => _baseClient.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) => _track(
      'GET',
      Uri(scheme: 'http', host: host, port: port, path: path),
      () => _baseClient.get(host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _track('GET', url, () => _baseClient.getUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) => _track(
      'POST',
      Uri(scheme: 'http', host: host, port: port, path: path),
      () => _baseClient.post(host, port, path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _track('POST', url, () => _baseClient.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) => _track(
      'PUT',
      Uri(scheme: 'http', host: host, port: port, path: path),
      () => _baseClient.put(host, port, path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _track('PUT', url, () => _baseClient.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _track('DELETE', Uri(scheme: 'http', host: host, port: port, path: path),
          () => _baseClient.delete(host, port, path));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _track('DELETE', url, () => _baseClient.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) => _track(
      'PATCH',
      Uri(scheme: 'http', host: host, port: port, path: path),
      () => _baseClient.patch(host, port, path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _track('PATCH', url, () => _baseClient.patchUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) => _track(
      'HEAD',
      Uri(scheme: 'http', host: host, port: port, path: path),
      () => _baseClient.head(host, port, path));

  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _track('HEAD', url, () => _baseClient.headUrl(url));

  @override
  void close({bool force = false}) => _baseClient.close(force: force);

  @override
  set authenticate(
      Future<bool> Function(Uri url, String scheme, String? realm)? f) {
    _baseClient.authenticate = f;
  }

  @override
  set authenticateProxy(
      Future<bool> Function(
              String host, int port, String scheme, String? realm)?
          f) {
    _baseClient.authenticateProxy = f;
  }

  @override
  set findProxy(String Function(Uri uri)? f) {
    _baseClient.findProxy = f;
  }

  /// Kept **and** forwarded. Kept because our factory is the only code that
  /// reaches the direct-HTTPS handshake; forwarded because the proxy tunnel
  /// still runs in the platform.
  @override
  set badCertificateCallback(
      bool Function(X509Certificate cert, String host, int port)? callback) {
    _badCertificateCallback = callback;
    _baseClient.badCertificateCallback = callback;
  }

  @override
  void addCredentials(
      Uri url, String realm, HttpClientCredentials credentials) {
    _baseClient.addCredentials(url, realm, credentials);
  }

  @override
  void addProxyCredentials(
      String host, int port, String realm, HttpClientCredentials credentials) {
    _baseClient.addProxyCredentials(host, port, realm, credentials);
  }

  /// Chained, never replaced — see [_consumerConnectionFactory].
  @override
  set connectionFactory(
      Future<ConnectionTask<Socket>> Function(
              Uri url, String? proxyHost, int? proxyPort)?
          f) {
    _consumerConnectionFactory = f;
  }

  /// Kept **and** forwarded, for the same reason as the certificate callback.
  @override
  set keyLog(Function(String line)? callback) {
    _keyLog = callback;
    _baseClient.keyLog = callback;
  }

  /// Start the clock, open the connection, and hand the request wrapper
  /// everything it needs to resolve its phases at completion.
  Future<HttpClientRequest> _track(
      String method, Uri url, Future<HttpClientRequest> Function() open) async {
    final callStart = DateTime.now();
    final HttpClientRequest request;
    try {
      request = await open();
    } catch (error) {
      // A connection that never opened — refused, DNS failure, no network. v2
      // could not report this at all: it started measuring only once `openUrl`
      // had already succeeded, so the whole offline case was invisible. The
      // re-based clock makes it a measured row.
      _onRequestComplete(HttpRequestTelemetry(
        url: url.toString(),
        method: method,
        statusCode: 0,
        duration: DateTime.now().difference(callStart),
        timestamp: callStart,
        error: error.toString(),
      ));
      rethrow;
    }
    return TelemetryHttpClientRequest(
      baseRequest: request,
      method: method,
      url: url,
      callStart: callStart,
      openMs: DateTime.now().difference(callStart).inMilliseconds,
      connects: _connects,
      onRequestComplete: _onRequestComplete,
      debugMode: debugMode,
    );
  }
}

/// The phase numbers a completed request resolved from its connect record.
/// Every field is nullable and every null is **omitted** on the wire — a key
/// the seam could not reach is absent, never zero and never sentinelled.
class HttpPhases {
  const HttpPhases({this.connectMs, this.dnsMs, this.queueMs, this.reused});

  final int? connectMs;
  final int? dnsMs;
  final int? queueMs;
  final bool? reused;
}

/// HTTP request wrapper that tracks timing and response data
class TelemetryHttpClientRequest implements HttpClientRequest {
  final HttpClientRequest _baseRequest;
  @override
  final String method;
  final Uri url;
  final Function(HttpRequestTelemetry) _onRequestComplete;
  final bool debugMode;

  /// Before the call, not after the connection — the re-base.
  final DateTime callStart;

  /// How long `openUrl` took: queue wait plus connect, when this request made
  /// the connection; queue wait alone when it reused one.
  final int openMs;

  final Map<int, HttpConnectRecord> _connects;

  /// Read now, while the connection is live — `connectionInfo` is null once
  /// the response is done with the socket.
  late final int? _localPort = _baseRequest.connectionInfo?.localPort;

  TelemetryHttpClientRequest({
    required HttpClientRequest baseRequest,
    required this.method,
    required this.url,
    required this.callStart,
    required this.openMs,
    required Map<int, HttpConnectRecord> connects,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
  })  : _baseRequest = baseRequest,
        _connects = connects,
        _onRequestComplete = onRequestComplete;

  /// Join this request to the connect record by local port, and claim it.
  ///
  /// No record means the seam never saw this socket connect (a consumer
  /// factory that made its own, or a connection older than capture) — so the
  /// reuse flag is unknown rather than false, and is omitted.
  HttpPhases _resolvePhases() {
    final port = _localPort;
    final record = port == null ? null : _connects[port];
    if (record == null) return const HttpPhases();
    if (record.claimed) {
      // Someone else connected this socket; this request only waited for it.
      return HttpPhases(queueMs: openMs, reused: true);
    }
    record.claimed = true;
    final queue = openMs - record.connectMs;
    return HttpPhases(
      connectMs: record.connectMs,
      dnsMs: record.dnsMs,
      queueMs: queue < 0 ? 0 : queue,
      reused: false,
    );
  }

  // Forward all properties to base request
  @override
  bool get persistentConnection => _baseRequest.persistentConnection;
  @override
  set persistentConnection(bool value) =>
      _baseRequest.persistentConnection = value;

  @override
  bool get followRedirects => _baseRequest.followRedirects;
  @override
  set followRedirects(bool value) => _baseRequest.followRedirects = value;

  @override
  int get maxRedirects => _baseRequest.maxRedirects;
  @override
  set maxRedirects(int value) => _baseRequest.maxRedirects = value;

  @override
  int get contentLength => _baseRequest.contentLength;
  @override
  set contentLength(int value) => _baseRequest.contentLength = value;

  @override
  bool get bufferOutput => _baseRequest.bufferOutput;
  @override
  set bufferOutput(bool value) => _baseRequest.bufferOutput = value;

  @override
  HttpHeaders get headers => _baseRequest.headers;

  @override
  List<Cookie> get cookies => _baseRequest.cookies;

  @override
  Future<HttpClientResponse> get done => _baseRequest.done;

  @override
  Future<HttpClientResponse> close() async {
    if (debugMode) {
      print('🌐 HTTP ${method.toUpperCase()} $url - Starting request...');
    }

    final phases = _resolvePhases();
    try {
      final response = await _baseRequest.close();
      return TelemetryHttpClientResponse(
        baseResponse: response,
        method: method,
        url: url,
        callStart: callStart,
        headersAt: DateTime.now(),
        phases: phases,
        onRequestComplete: _onRequestComplete,
        debugMode: debugMode,
      );
    } catch (error) {
      // A failed request still measures what it reached: the re-based clock
      // runs from before the call, so a connect failure now reports the
      // connect time it actually spent instead of a near-zero.
      _onRequestComplete(HttpRequestTelemetry(
        url: url.toString(),
        method: method,
        statusCode: 0,
        duration: DateTime.now().difference(callStart),
        timestamp: callStart,
        error: error.toString(),
        connectDuration: _ms(phases.connectMs),
        dnsDuration: _ms(phases.dnsMs),
        queueDuration: _ms(phases.queueMs),
        connectionReused: phases.reused,
      ));
      rethrow;
    }
  }

  @override
  HttpConnectionInfo? get connectionInfo => _baseRequest.connectionInfo;

  @override
  void add(List<int> data) => _baseRequest.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _baseRequest.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _baseRequest.addStream(stream);

  @override
  Future<void> flush() => _baseRequest.flush();

  @override
  void write(Object? object) => _baseRequest.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = ""]) =>
      _baseRequest.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _baseRequest.writeCharCode(charCode);

  @override
  void writeln([Object? object = ""]) => _baseRequest.writeln(object);

  @override
  Encoding get encoding => _baseRequest.encoding;
  @override
  set encoding(Encoding value) => _baseRequest.encoding = value;

  @override
  Uri get uri => _baseRequest.uri;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _baseRequest.abort(exception, stackTrace);
}

Duration? _ms(int? value) =>
    value == null ? null : Duration(milliseconds: value);

/// Response wrapper: counts the body, times the download tail, and emits the
/// one `http.request` telemetry record when the body ends.
///
/// **It emits at body end, not at headers.** Download time is the tail §8 asks
/// for separately, and a decoded-byte count has no value until the last byte.
/// The stream methods inherited from [Stream] all route through [listen], so
/// there is one counting path rather than thirty delegating ones.
///
// ponytail: a response whose body is never listened to never emits. dart:io
// requires the body be drained or the connection stalls, so that consumer is
// already broken; every real client (`package:http`, Dio, an idiomatic
// `dart:io` caller) drains. Add a one-shot fallback the day one does not.
class TelemetryHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final HttpClientResponse _baseResponse;
  final String method;
  final Uri url;
  final DateTime callStart;
  final DateTime headersAt;
  final HttpPhases phases;
  final Function(HttpRequestTelemetry) _onRequestComplete;
  final bool debugMode;

  int _decodedBytes = 0;
  bool _bodyComplete = false;
  bool _emitted = false;

  TelemetryHttpClientResponse({
    required HttpClientResponse baseResponse,
    required this.method,
    required this.url,
    required this.callStart,
    required this.headersAt,
    required this.phases,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
  })  : _baseResponse = baseResponse,
        _onRequestComplete = onRequestComplete;

  void _emitOnce() {
    if (_emitted) return;
    _emitted = true;

    final duration = headersAt.difference(callStart);
    final download = DateTime.now().difference(headersAt);

    if (debugMode) {
      print('🌐 HTTP ${method.toUpperCase()} $url - $statusCode '
          '(${duration.inMilliseconds}ms + ${download.inMilliseconds}ms body)');
    }

    // Content-length when the server gave one, else the bytes we decoded. The
    // two were measured **9x apart on one response**, and the platform reports
    // null on chunked encoding — i.e. on most modern JSON APIs — so the source
    // rides along rather than being assumed.
    // An unknown size is **omitted**, never a false zero: a body cancelled
    // part-way or a detached socket leaves a partial byte count, which is not
    // the response size and must not be sent as one.
    final declared = _baseResponse.contentLength;
    final int? size = declared >= 0
        ? declared
        : _bodyComplete
            ? _decodedBytes
            : null;

    _onRequestComplete(HttpRequestTelemetry(
      url: url.toString(),
      method: method,
      statusCode: statusCode,
      duration: duration,
      timestamp: callStart,
      downloadDuration: download,
      responseSize: size,
      responseSizeSource: size == null
          ? null
          : declared >= 0
              ? kSizeFromContentLength
              : kSizeFromDecodedBytes,
      connectDuration: _ms(phases.connectMs),
      dnsDuration: _ms(phases.dnsMs),
      queueDuration: _ms(phases.queueMs),
      connectionReused: phases.reused,
      redirectCount: _baseResponse.redirects.length,
    ));
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final counted = _baseResponse
        .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        _decodedBytes += chunk.length;
        sink.add(chunk);
      },
      handleError: (error, stack, sink) {
        _emitOnce();
        sink.addError(error, stack);
      },
      handleDone: (sink) {
        _bodyComplete = true;
        _emitOnce();
        sink.close();
      },
    ));
    return _TrackedSubscription(
      counted.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError),
      _emitOnce,
    );
  }

  @override
  Future<Socket> detachSocket() {
    // The body stops being ours the moment the socket is detached.
    _emitOnce();
    return _baseResponse.detachSocket();
  }

  // Forward the HttpClientResponse surface. Everything Stream already builds
  // on top of `listen` is deliberately NOT overridden.
  @override
  int get statusCode => _baseResponse.statusCode;

  @override
  String get reasonPhrase => _baseResponse.reasonPhrase;

  @override
  int get contentLength => _baseResponse.contentLength;

  @override
  HttpConnectionInfo? get connectionInfo => _baseResponse.connectionInfo;

  @override
  HttpHeaders get headers => _baseResponse.headers;

  @override
  List<Cookie> get cookies => _baseResponse.cookies;

  @override
  bool get isRedirect => _baseResponse.isRedirect;

  @override
  bool get persistentConnection => _baseResponse.persistentConnection;

  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _baseResponse.redirect(method, url, followLoops);

  @override
  List<RedirectInfo> get redirects => _baseResponse.redirects;

  @override
  X509Certificate? get certificate => _baseResponse.certificate;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _baseResponse.compressionState;
}

/// Cancellation is the fourth way a body ends (beside done, error and a
/// detached socket) and the only one a stream transformer cannot see.
class _TrackedSubscription implements StreamSubscription<List<int>> {
  _TrackedSubscription(this._inner, this._onEnd);

  final StreamSubscription<List<int>> _inner;
  final void Function() _onEnd;

  @override
  Future<void> cancel() {
    _onEnd();
    return _inner.cancel();
  }

  @override
  void onData(void Function(List<int>)? handleData) =>
      _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}

/// `http.response_size_source` when the server declared a content length.
const String kSizeFromContentLength = 'content_length';

/// `http.response_size_source` when the length came from counting decoded
/// bytes off the body stream.
const String kSizeFromDecodedBytes = 'decoded_bytes';

/// Data class for HTTP request telemetry.
///
/// Every duration here is a *measured* span. Nothing is derived and nothing is
/// guessed: total wall clock is [duration] + [downloadDuration], and
/// time-to-first-byte is [duration] - [connectDuration] - [queueDuration],
/// both derivable by the reader and therefore neither of them a key.
class HttpRequestTelemetry {
  final String url;
  final String method;
  final int statusCode;

  /// **Before the call to headers received.** v2 started this clock after the
  /// connection was already established and stopped it at the same place, so
  /// it measured neither connection setup nor content download — 149 ms
  /// reported against a 509 ms connect on a measured cold request.
  final Duration duration;

  /// When the call started (not when the connection did).
  final DateTime timestamp;

  final String? error;

  /// Headers received to last byte of the body.
  final Duration? downloadDuration;

  final int? responseSize;

  /// [kSizeFromContentLength] or [kSizeFromDecodedBytes] — the two disagreed
  /// by 9x on one measured response, so which one this is travels with it.
  final String? responseSizeSource;

  /// Fused DNS + TCP + TLS. Absent when this request reused a connection (it
  /// connected nothing) or when the seam never saw the socket connect.
  final Duration? connectDuration;

  /// Name resolution, split out of [connectDuration] at the `diagnostic` tier
  /// only — it costs a resolver call the platform does not make.
  final Duration? dnsDuration;

  /// Waiting for a free connection from the pool.
  final Duration? queueDuration;

  /// Measured by joining the request's local port to the connect record —
  /// never inferred from a fast connect. Null when no record was found.
  final bool? connectionReused;

  final int? redirectCount;

  const HttpRequestTelemetry({
    required this.url,
    required this.method,
    required this.statusCode,
    required this.duration,
    required this.timestamp,
    this.error,
    this.responseSize,
    this.downloadDuration,
    this.responseSizeSource,
    this.connectDuration,
    this.dnsDuration,
    this.queueDuration,
    this.connectionReused,
    this.redirectCount,
  });

  /// Convert to attributes map for telemetry.
  ///
  /// [fullUrl] and [phases] are the two `diagnostic` switches (`Capture
  /// .httpQueryString` and `Capture.httpPhaseTiming`); the capture hook
  /// resolves both before calling, so the default-tier map is built once and
  /// carries only the default-tier keys.
  ///
  /// **There is no retry key and there will not be one.** At this seam a retry
  /// is a new independent request, indistinguishable from a double-tap or a
  /// poll; the offline experience is a query-time view joining these rows to
  /// the `network_change` stream on session and time.
  Map<String, String> toAttributes({
    bool fullUrl = false,
    bool phases = false,
  }) {
    final uri = Uri.tryParse(url);
    final sent = fullUrl || uri == null ? url : redactUrl(uri);

    return {
      'http.url': sent,
      'http.url_redacted': (sent != url).toString(),
      'http.method': method,
      'http.status_code': statusCode.toString(),
      'http.duration_ms': duration.inMilliseconds.toString(),
      if (downloadDuration != null)
        'http.download_ms': downloadDuration!.inMilliseconds.toString(),
      if (connectDuration != null)
        'http.connect_ms': connectDuration!.inMilliseconds.toString(),
      if (connectionReused != null)
        'http.connection_reused': connectionReused!.toString(),
      if (phases && dnsDuration != null)
        'http.dns_ms': dnsDuration!.inMilliseconds.toString(),
      if (phases && queueDuration != null)
        'http.queue_ms': queueDuration!.inMilliseconds.toString(),
      if (phases && redirectCount != null)
        'http.redirect_count': redirectCount!.toString(),
      'http.timestamp': timestamp.toIso8601String(),
      if (error != null) 'http.error': error!,
      if (responseSize != null) 'http.response_size': responseSize.toString(),
      if (responseSizeSource != null)
        'http.response_size_source': responseSizeSource!,
      'http.success': isSuccess.toString(),
      'http.seam': kSeam,
    };
  }

  /// Get request category (success, client error, server error, etc.)
  String get category {
    if (error != null) return 'network_error';
    if (statusCode >= 200 && statusCode < 300) return 'success';
    if (statusCode >= 300 && statusCode < 400) return 'redirect';
    if (statusCode >= 400 && statusCode < 500) return 'client_error';
    if (statusCode >= 500) return 'server_error';
    return 'unknown';
  }

  /// **2xx only** (v2 counted 3xx as success too). The platform follows
  /// redirects by default, so almost no row changes — and the family's
  /// cross-SDK error rate stops disagreeing with itself on a shipped key.
  bool get isSuccess => statusCode >= 200 && statusCode < 300 && error == null;

  /// Get performance category based on duration
  String get performanceCategory {
    final ms = duration.inMilliseconds;
    if (ms < 100) return 'fast';
    if (ms < 500) return 'normal';
    if (ms < 2000) return 'slow';
    return 'very_slow';
  }
}
