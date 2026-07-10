// lib/src/http/telemetry_http_overrides.dart

import 'dart:async';
import 'dart:convert'; // Add this import for Encoding class
import 'dart:io';

/// HTTP overrides that automatically monitor all network requests
///
/// Wraps the default HttpClient to inject telemetry tracking
/// for every HTTP request made by the app
class TelemetryHttpOverrides extends HttpOverrides {
  final HttpOverrides? _previousOverrides;
  final Function(HttpRequestTelemetry) _onRequestComplete;
  final bool debugMode;

  TelemetryHttpOverrides({
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
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
    );
  }

  /// Install global HTTP monitoring
  static void installGlobal({
    required Function(HttpRequestTelemetry) onRequestComplete,
    bool debugMode = false,
  }) {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = TelemetryHttpOverrides(
      onRequestComplete: onRequestComplete,
      debugMode: debugMode,
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

/// HTTP client wrapper that tracks all requests
class TelemetryHttpClient implements HttpClient {
  final HttpClient _baseClient;
  final Function(HttpRequestTelemetry) _onRequestComplete;
  final bool debugMode;

  TelemetryHttpClient({
    required HttpClient baseClient,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
  })  : _baseClient = baseClient,
        _onRequestComplete = onRequestComplete;

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

  // Proxy all HTTP methods through our tracking wrapper
  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) async {
    final request = await _baseClient.open(method, host, port, path);
    return _wrapRequest(request, method,
        Uri(scheme: 'http', host: host, port: port, path: path));
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _baseClient.openUrl(method, url);
    return _wrapRequest(request, method, url);
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) async {
    final request = await _baseClient.get(host, port, path);
    return _wrapRequest(request, 'GET',
        Uri(scheme: 'http', host: host, port: port, path: path));
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final request = await _baseClient.getUrl(url);
    return _wrapRequest(request, 'GET', url);
  }

  @override
  Future<HttpClientRequest> post(String host, int port, String path) async {
    final request = await _baseClient.post(host, port, path);
    return _wrapRequest(request, 'POST',
        Uri(scheme: 'http', host: host, port: port, path: path));
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final request = await _baseClient.postUrl(url);
    return _wrapRequest(request, 'POST', url);
  }

  @override
  Future<HttpClientRequest> put(String host, int port, String path) async {
    final request = await _baseClient.put(host, port, path);
    return _wrapRequest(request, 'PUT',
        Uri(scheme: 'http', host: host, port: port, path: path));
  }

  @override
  Future<HttpClientRequest> putUrl(Uri url) async {
    final request = await _baseClient.putUrl(url);
    return _wrapRequest(request, 'PUT', url);
  }

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) async {
    final request = await _baseClient.delete(host, port, path);
    return _wrapRequest(request, 'DELETE',
        Uri(scheme: 'http', host: host, port: port, path: path));
  }

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) async {
    final request = await _baseClient.deleteUrl(url);
    return _wrapRequest(request, 'DELETE', url);
  }

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) async {
    final request = await _baseClient.patch(host, port, path);
    return _wrapRequest(request, 'PATCH',
        Uri(scheme: 'http', host: host, port: port, path: path));
  }

  @override
  Future<HttpClientRequest> patchUrl(Uri url) async {
    final request = await _baseClient.patchUrl(url);
    return _wrapRequest(request, 'PATCH', url);
  }

  @override
  Future<HttpClientRequest> head(String host, int port, String path) async {
    final request = await _baseClient.head(host, port, path);
    return _wrapRequest(request, 'HEAD',
        Uri(scheme: 'http', host: host, port: port, path: path));
  }

  @override
  Future<HttpClientRequest> headUrl(Uri url) async {
    final request = await _baseClient.headUrl(url);
    return _wrapRequest(request, 'HEAD', url);
  }

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

  @override
  set badCertificateCallback(
      bool Function(X509Certificate cert, String host, int port)? callback) {
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

  @override
  set connectionFactory(
      Future<ConnectionTask<Socket>> Function(
              Uri url, String? proxyHost, int? proxyPort)?
          f) {
    _baseClient.connectionFactory = f;
  }

  @override
  set keyLog(Function(String line)? callback) {
    _baseClient.keyLog = callback;
  }

  /// Wrap an HTTP request to track its telemetry
  TelemetryHttpClientRequest _wrapRequest(
      HttpClientRequest request, String method, Uri url) {
    return TelemetryHttpClientRequest(
      baseRequest: request,
      method: method,
      url: url,
      onRequestComplete: _onRequestComplete,
      debugMode: debugMode,
    );
  }
}

/// HTTP request wrapper that tracks timing and response data
class TelemetryHttpClientRequest implements HttpClientRequest {
  final HttpClientRequest _baseRequest;
  final String method;
  final Uri url;
  final Function(HttpRequestTelemetry) _onRequestComplete;
  final bool debugMode;
  final DateTime _startTime = DateTime.now();

  TelemetryHttpClientRequest({
    required HttpClientRequest baseRequest,
    required this.method,
    required this.url,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
  })  : _baseRequest = baseRequest,
        _onRequestComplete = onRequestComplete;

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
      print('🌐 HTTP ${method.toUpperCase()} ${url} - Starting request...');
    }

    try {
      final response = await _baseRequest.close();
      return TelemetryHttpClientResponse(
        baseResponse: response,
        method: method,
        url: url,
        startTime: _startTime,
        onRequestComplete: _onRequestComplete,
        debugMode: debugMode,
      );
    } catch (error) {
      // Track failed request
      _trackRequest(
        url: url,
        method: method,
        statusCode: 0,
        duration: DateTime.now().difference(_startTime),
        error: error.toString(),
      );
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

  void _trackRequest({
    required Uri url,
    required String method,
    required int statusCode,
    required Duration duration,
    String? error,
    int? responseSize,
  }) {
    final telemetry = HttpRequestTelemetry(
      url: url.toString(),
      method: method,
      statusCode: statusCode,
      duration: duration,
      timestamp: _startTime,
      error: error,
      responseSize: responseSize,
    );

    _onRequestComplete(telemetry);
  }
}

/// HTTP response wrapper that captures response data
class TelemetryHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final HttpClientResponse _baseResponse;
  final String method;
  final Uri url;
  final DateTime startTime;
  final Function(HttpRequestTelemetry) _onRequestComplete;
  final bool debugMode;

  TelemetryHttpClientResponse({
    required HttpClientResponse baseResponse,
    required this.method,
    required this.url,
    required this.startTime,
    required Function(HttpRequestTelemetry) onRequestComplete,
    this.debugMode = false,
  })  : _baseResponse = baseResponse,
        _onRequestComplete = onRequestComplete {
    // Track the response immediately
    _trackResponse();
  }

  void _trackResponse() {
    final duration = DateTime.now().difference(startTime);

    if (debugMode) {
      print(
          '🌐 HTTP ${method.toUpperCase()} ${url} - ${statusCode} (${duration.inMilliseconds}ms)');
    }

    final telemetry = HttpRequestTelemetry(
      url: url.toString(),
      method: method,
      statusCode: statusCode,
      duration: duration,
      timestamp: startTime,
      responseSize: contentLength >= 0 ? contentLength : null,
    );

    _onRequestComplete(telemetry);
  }

  // Forward all properties to base response
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
  Future<Socket> detachSocket() => _baseResponse.detachSocket();

  @override
  List<RedirectInfo> get redirects => _baseResponse.redirects;

  @override
  Future<void> forEach(void Function(List<int>) action) =>
      _baseResponse.forEach(action);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _baseResponse.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  X509Certificate? get certificate => _baseResponse.certificate;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _baseResponse.compressionState;

  // Additional Stream methods
  @override
  Future<bool> any(bool Function(List<int>) test) => _baseResponse.any(test);

  @override
  Stream<List<int>> asBroadcastStream({
    void Function(StreamSubscription<List<int>>)? onListen,
    void Function(StreamSubscription<List<int>>)? onCancel,
  }) =>
      _baseResponse.asBroadcastStream(onListen: onListen, onCancel: onCancel);

  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(List<int>) convert) =>
      _baseResponse.asyncExpand(convert);

  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(List<int>) convert) =>
      _baseResponse.asyncMap(convert);

  @override
  Stream<R> cast<R>() => _baseResponse.cast<R>();

  @override
  Future<bool> contains(Object? needle) => _baseResponse.contains(needle);

  @override
  Stream<List<int>> distinct([bool Function(List<int>, List<int>)? equals]) =>
      _baseResponse.distinct(equals);

  @override
  Future<E> drain<E>([E? futureValue]) => _baseResponse.drain(futureValue);

  @override
  Future<List<int>> elementAt(int index) => _baseResponse.elementAt(index);

  @override
  Future<bool> every(bool Function(List<int>) test) =>
      _baseResponse.every(test);

  @override
  Stream<E> expand<E>(Iterable<E> Function(List<int>) convert) =>
      _baseResponse.expand(convert);

  @override
  Future<List<int>> get first => _baseResponse.first;

  @override
  Future<List<int>> firstWhere(bool Function(List<int>) test,
          {List<int> Function()? orElse}) =>
      _baseResponse.firstWhere(test, orElse: orElse);

  @override
  Future<E> fold<E>(E initialValue, E Function(E, List<int>) combine) =>
      _baseResponse.fold(initialValue, combine);

  @override
  Future<void> pipe(StreamConsumer<List<int>> streamConsumer) =>
      _baseResponse.pipe(streamConsumer);

  @override
  Future<List<int>> reduce(List<int> Function(List<int>, List<int>) combine) =>
      _baseResponse.reduce(combine);

  @override
  Future<List<int>> get single => _baseResponse.single;

  @override
  Future<List<int>> singleWhere(bool Function(List<int>) test,
          {List<int> Function()? orElse}) =>
      _baseResponse.singleWhere(test, orElse: orElse);

  @override
  Stream<List<int>> skip(int count) => _baseResponse.skip(count);

  @override
  Stream<List<int>> skipWhile(bool Function(List<int>) test) =>
      _baseResponse.skipWhile(test);

  @override
  Stream<List<int>> take(int count) => _baseResponse.take(count);

  @override
  Stream<List<int>> takeWhile(bool Function(List<int>) test) =>
      _baseResponse.takeWhile(test);

  @override
  Stream<List<int>> timeout(Duration timeLimit,
          {void Function(EventSink<List<int>>)? onTimeout}) =>
      _baseResponse.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<List<List<int>>> toList() => _baseResponse.toList();

  @override
  Future<Set<List<int>>> toSet() => _baseResponse.toSet();

  @override
  Stream<E> transform<E>(StreamTransformer<List<int>, E> streamTransformer) =>
      _baseResponse.transform(streamTransformer);

  @override
  Stream<List<int>> where(bool Function(List<int>) test) =>
      _baseResponse.where(test);

  @override
  Future<List<int>> get last => _baseResponse.last;

  @override
  Future<List<int>> lastWhere(bool Function(List<int>) test,
          {List<int> Function()? orElse}) =>
      _baseResponse.lastWhere(test, orElse: orElse);

  @override
  Future<int> get length => _baseResponse.length;

  @override
  Future<bool> get isEmpty => _baseResponse.isEmpty;

  @override
  Stream<E> map<E>(E Function(List<int>) convert) => _baseResponse.map(convert);
}

/// Data class for HTTP request telemetry
class HttpRequestTelemetry {
  final String url;
  final String method;
  final int statusCode;
  final Duration duration;
  final DateTime timestamp;
  final String? error;
  final int? responseSize;

  const HttpRequestTelemetry({
    required this.url,
    required this.method,
    required this.statusCode,
    required this.duration,
    required this.timestamp,
    this.error,
    this.responseSize,
  });

  /// Convert to attributes map for telemetry
  Map<String, String> toAttributes() {
    return {
      'http.url': url,
      'http.method': method,
      'http.status_code': statusCode.toString(),
      'http.duration_ms': duration.inMilliseconds.toString(),
      'http.timestamp': timestamp.toIso8601String(),
      if (error != null) 'http.error': error!,
      if (responseSize != null) 'http.response_size': responseSize.toString(),
      'http.success': (statusCode >= 200 && statusCode < 400).toString(),
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

  /// Check if request was successful
  bool get isSuccess => statusCode >= 200 && statusCode < 400 && error == null;

  /// Get performance category based on duration
  String get performanceCategory {
    final ms = duration.inMilliseconds;
    if (ms < 100) return 'fast';
    if (ms < 500) return 'normal';
    if (ms < 2000) return 'slow';
    return 'very_slow';
  }
}
