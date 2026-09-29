// lib/src/capture/http_overrides.dart
//
// The `dart:io` seam: `HttpOverrides.global` wrappers plus the
// [HttpRequestTelemetry] data class. One of the two seams §8 names — the other
// is the wrapper seam (#87), which is why every request carries [kSeam].

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'http_url.dart';
import 'trace_injection.dart';

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

  /// The propagation half (#86). Null = no header and no trace keys — the shape
  /// a faked hook runs in.
  final TraceInjector? injector;

  /// The SDK's own upload target, excluded **explicitly** rather than by
  /// construction order. See [TelemetryHttpClient.isSelfUpload].
  final Uri? selfUrl;

  TelemetryHttpOverrides({
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
    this.measurePhases = false,
    this.injector,
    this.selfUrl,
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
      injector: injector,
      selfUrl: selfUrl,
      // Threaded by hand, and load-bearing — see [TelemetryHttpClient].
      securityContext: context,
    );
  }

  /// Install global HTTP monitoring
  static void installGlobal({
    required Function(HttpRequestTelemetry) onRequestComplete,
    bool debugMode = false,
    bool measurePhases = false,
    TraceInjector? injector,
    Uri? selfUrl,
  }) {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = TelemetryHttpOverrides(
      onRequestComplete: onRequestComplete,
      debugMode: debugMode,
      measurePhases: measurePhases,
      injector: injector,
      selfUrl: selfUrl,
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
/// [claim] is what makes the reuse flag *measured* rather than inferred: the
/// first request over a socket claims the record, every later request on the
/// same local port finds it claimed and is a reuse.
class HttpConnectRecord {
  HttpConnectRecord({required this.connect, this.dns});

  final Duration connect;
  final Duration? dns;
  bool _claimed = false;

  /// Report this connection to the request whose `openUrl` took [openMs], and
  /// claim it if nobody has. The second and later requests over the socket get
  /// the reuse flag and their queue wait, and no connect time — they connected
  /// nothing, and a zero there would be a lie the backend cannot detect.
  HttpPhases claim(int openMs) {
    if (_claimed) {
      return HttpPhases(queue: Duration(milliseconds: openMs), reused: true);
    }
    _claimed = true;
    final queue = openMs - connect.inMilliseconds;
    return HttpPhases(
      connect: connect,
      dns: dns,
      queue: Duration(milliseconds: queue < 0 ? 0 : queue),
      reused: false,
    );
  }
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

  /// The propagation half (#86); null leaves every request un-traced.
  final TraceInjector? injector;

  /// The collector URL `RetryTransport` resolved. See [isSelfUpload].
  final Uri? selfUrl;

  TelemetryHttpClient({
    required HttpClient baseClient,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
    this.measurePhases = false,
    this.injector,
    this.selfUrl,
    SecurityContext? securityContext,
  })  : _baseClient = baseClient,
        _onRequestComplete = onRequestComplete,
        _securityContext = securityContext {
    _baseClient.connectionFactory = _connect;
  }

  /// Whether [url] is the SDK's own telemetry POST.
  ///
  /// **Explicit, not by construction order** (#55 D10). `RetryTransport` builds
  /// its `HttpClient` before the hook installs the global override, so today
  /// self-capture is prevented by luck — undocumented, and one refactor from
  /// breaking. The failure mode is not cosmetic: every upload would emit an
  /// `http.request`, which enters the next batch, which is another upload —
  /// unbounded amplification — and the collector would receive a `traceparent`
  /// it removed its ingestion path for. A self-upload emits no event, injects
  /// no header, and per the outcome contract carries no outcome key at all.
  ///
  /// The check is free: the wrapper is already comparing hosts for the
  /// allowlist, so this is one more comparison on a path already comparing.
  bool isSelfUpload(Uri url) {
    final self = selfUrl;
    return self != null &&
        url.scheme == self.scheme &&
        url.host == self.host &&
        url.port == self.port &&
        url.path == self.path;
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
    // Monotonic: a wall clock spanning an NTP correction can report a negative
    // connect time. Every duration in this file comes off a Stopwatch; only
    // timestamps stay wall-clock, because they must be absolute to join.
    final elapsed = Stopwatch()..start();
    final consumer = _consumerConnectionFactory;

    Duration? dns;
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
        dns = elapsed.elapsed;
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
        connect: elapsed.elapsed,
        dns: dns,
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
      _track(method, _plainUri(host, port, path),
          () => _baseClient.open(method, host, port, path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _track(method, url, () => _baseClient.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) => _track(
      'GET',
      _plainUri(host, port, path),
      () => _baseClient.get(host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _track('GET', url, () => _baseClient.getUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) => _track(
      'POST',
      _plainUri(host, port, path),
      () => _baseClient.post(host, port, path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _track('POST', url, () => _baseClient.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) => _track(
      'PUT',
      _plainUri(host, port, path),
      () => _baseClient.put(host, port, path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _track('PUT', url, () => _baseClient.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _track('DELETE', _plainUri(host, port, path),
          () => _baseClient.delete(host, port, path));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _track('DELETE', url, () => _baseClient.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) => _track(
      'PATCH',
      _plainUri(host, port, path),
      () => _baseClient.patch(host, port, path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _track('PATCH', url, () => _baseClient.patchUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) => _track(
      'HEAD',
      _plainUri(host, port, path),
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

  /// The URL shape the host/port/path overloads describe. They predate
  /// `openUrl` and carry no scheme of their own.
  static Uri _plainUri(String host, int port, String path) =>
      Uri(scheme: 'http', host: host, port: port, path: path);

  /// Start the clock, open the connection, and hand the request wrapper
  /// everything it needs to resolve its phases at completion.
  Future<HttpClientRequest> _track(
      String method, Uri url, Future<HttpClientRequest> Function() open) async {
    // Before anything else, and before the first await: the SDK's own upload is
    // not a request the SDK reports on.
    if (isSelfUpload(url)) return open();

    // **The freeze**, on entry to the override and before the base client is
    // awaited. That await measured 509 ms cold and the host app may await again
    // before `close()` — two supersede opportunities before a single byte is
    // injected. The causal parent is the action that called the API, not
    // whatever tap landed during a TLS handshake.
    final freeze = injector?.freeze() ?? (carrier: null, expired: false);
    final callStart = DateTime.now();
    final clock = Stopwatch()..start();
    final HttpClientRequest request;
    try {
      request = await open();
    } catch (error) {
      // A connection that never opened — refused, DNS failure, no network. v2
      // could not report this at all: it started measuring only once `openUrl`
      // had already succeeded, so the whole offline case was invisible. The
      // re-based clock makes it a measured row.
      //
      // It carries the frozen ids but **no outcome**: no header was ever
      // written, and absence is the contract's own member for "not traced".
      _onRequestComplete(_failed(url, method, callStart, clock, error,
          traceAttributes: injector?.stamp(freeze) ?? const {}));
      rethrow;
    }
    return TelemetryHttpClientRequest(
      baseRequest: request,
      method: method,
      url: url,
      callStart: callStart,
      clock: clock,
      openMs: clock.elapsedMilliseconds,
      connects: _connects,
      onRequestComplete: _onRequestComplete,
      debugMode: debugMode,
      injector: injector,
      freeze: freeze,
    );
  }
}

/// The phase numbers a completed request resolved from its connect record.
/// Every field is nullable and every null is **omitted** on the wire — a key
/// the seam could not reach is absent, never zero and never sentinelled.
class HttpPhases {
  const HttpPhases({this.connect, this.dns, this.queue, this.reused});

  final Duration? connect;
  final Duration? dns;
  final Duration? queue;
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

  /// Before the call, not after the connection — the re-base. Wall clock,
  /// because `span.start_time` must be absolute to join a client span to a
  /// server one; every *duration* comes off [elapsed] instead.
  final DateTime callStart;

  /// The one monotonic clock for this request, started beside [callStart].
  final Stopwatch clock;

  /// How long `openUrl` took: queue wait plus connect, when this request made
  /// the connection; queue wait alone when it reused one.
  final int openMs;

  /// The propagation half, and what it froze at the call instant.
  final TraceInjector? injector;
  final TraceFreeze freeze;

  /// Resolved once, at [_injectOnce].
  Map<String, String> _traceAttributes = const {};
  bool _injected = false;

  final Map<int, HttpConnectRecord> _connects;

  /// Read now, while the connection is live — `connectionInfo` is null once
  /// the response is done with the socket.
  late final int? _localPort = _baseRequest.connectionInfo?.localPort;

  TelemetryHttpClientRequest({
    required HttpClientRequest baseRequest,
    required this.method,
    required this.url,
    required this.callStart,
    required this.clock,
    required this.openMs,
    required Map<int, HttpConnectRecord> connects,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
    this.injector,
    this.freeze = (carrier: null, expired: false),
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
    return _connects[port]?.claim(openMs) ?? const HttpPhases();
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
    _injectOnce();

    try {
      final response = await _baseRequest.close();
      return TelemetryHttpClientResponse(
        baseResponse: response,
        method: method,
        url: url,
        callStart: callStart,
        clock: clock,
        elapsedAtHeaders: clock.elapsed,
        phases: phases,
        traceAttributes: _traceAttributes,
        onRequestComplete: _onRequestComplete,
        debugMode: debugMode,
      );
    } catch (error) {
      // A failed request still measures what it reached: the re-based clock
      // runs from before the call, so a connect failure now reports the
      // connect time it actually spent instead of a near-zero.
      _onRequestComplete(_failed(url, method, callStart, clock, error,
          phases: phases, traceAttributes: _traceAttributes));
      rethrow;
    }
  }

  /// Resolve the ladder and write the header — **at the last instant the
  /// header map is still mutable**, which is the first body byte, not `close()`.
  ///
  /// `dart:io` sends the header section on the first write and freezes the map
  /// with it, so injecting at `close()` throws `HttpException: HTTP headers are
  /// not mutable` out of the consumer's own `close()` on every request with a
  /// body. An SDK that makes the host app's POSTs throw is the exact class of
  /// harm the redirect leak was declined to avoid.
  ///
  /// It still runs after the consumer has set their own headers — they set them
  /// before writing a body — so the adopt rung is unaffected.
  void _injectOnce() {
    if (_injected) return;
    _injected = true;
    final resolver = injector;
    if (resolver == null) return;

    final decision = resolver.resolve(
      url: url,
      inbound: _inboundTraceparent(),
      freeze: freeze,
    );
    _traceAttributes = decision.attributes;
    final header = decision.header;
    if (header == null) return;
    try {
      headers.set(kTraceparentHeader, header);
    } catch (_) {
      // Unreachable through this wrapper, and swallowed rather than thrown:
      // the SDK must never be why a consumer's request fails. The ids stay on
      // the row, the outcome key comes off — nothing was propagated, and
      // absence is the contract's member for that.
      _traceAttributes = Map<String, String>.from(decision.attributes)
        ..remove('traceparent.outcome');
    }
  }

  /// The consumer's own `traceparent`, if they set one — the adopt rung.
  /// `HttpHeaders.value` throws when a header carries more than one value, and
  /// two `traceparent`s is malformed anyway, so that reads as "none".
  String? _inboundTraceparent() {
    try {
      return headers.value(kTraceparentHeader);
    } catch (_) {
      return null;
    }
  }

  @override
  HttpConnectionInfo? get connectionInfo => _baseRequest.connectionInfo;

  @override
  void add(List<int> data) {
    _injectOnce();
    _baseRequest.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _baseRequest.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _injectOnce();
    return _baseRequest.addStream(stream);
  }

  @override
  Future<void> flush() {
    _injectOnce();
    return _baseRequest.flush();
  }

  @override
  void write(Object? object) {
    _injectOnce();
    _baseRequest.write(object);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = ""]) {
    _injectOnce();
    _baseRequest.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _injectOnce();
    _baseRequest.writeCharCode(charCode);
  }

  @override
  void writeln([Object? object = ""]) {
    _injectOnce();
    _baseRequest.writeln(object);
  }

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

/// The one shape a request that produced no response takes — a refused
/// connection, a DNS failure, a socket that died mid-flight.
HttpRequestTelemetry _failed(
  Uri url,
  String method,
  DateTime callStart,
  Stopwatch clock,
  Object error, {
  HttpPhases phases = const HttpPhases(),
  Map<String, String> traceAttributes = const {},
}) =>
    HttpRequestTelemetry(
      url: url.toString(),
      method: method,
      statusCode: 0,
      duration: clock.elapsed,
      timestamp: callStart,
      error: error.toString(),
      traceAttributes: traceAttributes,
      connectDuration: phases.connect,
      dnsDuration: phases.dns,
      queueDuration: phases.queue,
      connectionReused: phases.reused,
    );

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
  final Stopwatch clock;
  final Duration elapsedAtHeaders;
  final HttpPhases phases;
  final Map<String, String> traceAttributes;
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
    required this.clock,
    required this.elapsedAtHeaders,
    required this.phases,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.traceAttributes = const {},
    this.debugMode = false,
  })  : _baseResponse = baseResponse,
        _onRequestComplete = onRequestComplete;

  void _emitOnce() {
    if (_emitted) return;
    _emitted = true;

    final duration = elapsedAtHeaders;
    final download = clock.elapsed - elapsedAtHeaders;

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
      connectDuration: phases.connect,
      dnsDuration: phases.dns,
      queueDuration: phases.queue,
      connectionReused: phases.reused,
      redirectCount: _baseResponse.redirects.length,
      traceAttributes: traceAttributes,
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

  /// The frozen trace keys plus `traceparent.outcome`, resolved at inject from
  /// the same copy the header was built from. Empty when nothing was traced —
  /// and absence of the outcome key is itself the contract's "not traced".
  final Map<String, String> traceAttributes;

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
    this.traceAttributes = const {},
  });

  /// Convert to attributes map for telemetry.
  ///
  /// [fullUrl] and [phases] are the two `diagnostic` switches (`Capture
  /// .httpQueryString` and `Capture.httpRequestPhases`); the capture hook
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
    // A URL the platform will not parse is still not allowed to ship its query
    // at the default tier — the flag would say `false` on the one row that
    // needed it to say `true`.
    final sent = fullUrl
        ? url
        : uri == null
            ? url.split('#').first.split('?').first
            : redactUrl(uri);

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
      // Absolute UTC, RFC3339 — the processor's `parseTime` returns a silent
      // NULL on anything else, so epoch millis would vanish without an error.
      'span.start_time': timestamp.toUtc().toIso8601String(),
      // Children only — a root derives its duration server-side from its
      // children, so a re-rooted (or adopted, root-shaped) request sends none.
      // The measurement is not lost: `http.duration_ms` carries it either way.
      if (traceAttributes.containsKey('parent.span.id'))
        'span.duration_ms': (duration + (downloadDuration ?? Duration.zero))
            .inMilliseconds
            .toString(),
      ...traceAttributes,
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
