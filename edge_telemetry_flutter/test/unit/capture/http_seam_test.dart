// test/unit/capture/http_seam_test.dart
//
// #85 driven through the real `dart:io` seam against loopback servers. These
// are the assertions the shape tests cannot make: that the clock is re-based
// before the call, that the reuse flag is measured rather than inferred, and
// that installing a connection factory did not silently disable certificate
// pinning.

import 'dart:async';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/capture/http_overrides.dart';
import 'package:flutter_test/flutter_test.dart';

const String _certPath = 'test/fixtures/tls/localhost_cert.pem';
const String _keyPath = 'test/fixtures/tls/localhost_key.pem';
const String _caPath = 'test/fixtures/tls/ca_cert.pem';

void main() {
  late List<HttpRequestTelemetry> records;
  HttpOverrides? saved;

  setUp(() {
    records = [];
    // flutter_test installs its own overrides (a mock client for image
    // loading). Drop them for the duration, or every socket here is faked.
    saved = HttpOverrides.current;
    HttpOverrides.global = null;
    TelemetryHttpOverrides.installGlobal(onRequestComplete: records.add);
  });

  tearDown(() {
    TelemetryHttpOverrides.uninstallGlobal();
    HttpOverrides.global = saved;
  });

  /// A loopback server that flushes its headers with the first byte, waits
  /// [bodyGap], then sends the rest — so headers-received and last-byte are
  /// separable in the record.
  Future<HttpServer> serve({
    Duration bodyGap = Duration.zero,
    bool declareLength = false,
    String body = 'response-body-padding',
    int status = 200,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((req) async {
      await req.drain<void>();
      final res = req.response..statusCode = status;
      if (declareLength) res.contentLength = body.length;
      res.write(body.substring(0, 1));
      await res.flush();
      if (bodyGap > Duration.zero) await Future<void>.delayed(bodyGap);
      res.write(body.substring(1));
      await res.close();
    }));
    return server;
  }

  Future<void> fetch(HttpClient client, Uri url) async {
    final request = await client.getUrl(url);
    final response = await request.close();
    await response.drain<void>();
  }

  test('the clock starts before the call, not after the connection', () async {
    final server = await serve();
    addTearDown(() => server.close(force: true));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    // A consumer factory that takes a measurable 80 ms. It doubles as the
    // chaining assertion: ours wraps theirs rather than replacing it.
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      return Socket.startConnect(url.host, url.port);
    };

    await fetch(client, Uri.parse('http://127.0.0.1:${server.port}/health'));

    final record = records.single;
    expect(record.connectDuration!.inMilliseconds, greaterThanOrEqualTo(70));
    expect(record.duration.inMilliseconds, greaterThanOrEqualTo(70),
        reason: 'v2 started the clock after openUrl and reported ~0 here');
  });

  test('download time carries the tail, separately from the total', () async {
    final server = await serve(bodyGap: const Duration(milliseconds: 120));
    addTearDown(() => server.close(force: true));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await fetch(client, Uri.parse('http://127.0.0.1:${server.port}/slow'));

    final record = records.single;
    expect(record.downloadDuration!.inMilliseconds, greaterThanOrEqualTo(110));
    expect(record.duration.inMilliseconds,
        lessThan(record.downloadDuration!.inMilliseconds),
        reason: 'headers arrived with the first byte, long before the last');
  });

  test('connection reuse is measured by the local-port join', () async {
    final server = await serve();
    addTearDown(() => server.close(force: true));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final url = Uri.parse('http://127.0.0.1:${server.port}/a');
    await fetch(client, url);
    await fetch(client, url);

    expect(records, hasLength(2));
    expect(records[0].connectionReused, isFalse);
    expect(records[0].connectDuration, isNotNull);

    expect(records[1].connectionReused, isTrue);
    expect(records[1].connectDuration, isNull,
        reason: 'a reused request connected nothing — omit, never zero');
  });

  test('response size names its source', () async {
    const body = 'response-body-padding';

    final chunked = await serve();
    addTearDown(() => chunked.close(force: true));
    final c1 = HttpClient();
    addTearDown(() => c1.close(force: true));
    await fetch(c1, Uri.parse('http://127.0.0.1:${chunked.port}/x'));

    expect(records.single.responseSizeSource, kSizeFromDecodedBytes);
    expect(records.single.responseSize, body.length);

    records.clear();
    final declared = await serve(declareLength: true);
    addTearDown(() => declared.close(force: true));
    final c2 = HttpClient();
    addTearDown(() => c2.close(force: true));
    await fetch(c2, Uri.parse('http://127.0.0.1:${declared.port}/x'));

    expect(records.single.responseSizeSource, kSizeFromContentLength);
    expect(records.single.responseSize, body.length);
  });

  test('a connection that never opened is still a measured row', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    // Port 1 on loopback: nothing listens, the connect is refused.
    await expectLater(
      client.getUrl(Uri.parse('http://127.0.0.1:1/nope')),
      throwsA(isA<SocketException>()),
    );

    final record = records.single;
    expect(record.statusCode, 0);
    expect(record.error, isNotNull);
    expect(record.isSuccess, isFalse);
  });

  group('certificate pinning survives capture', () {
    late HttpServer server;
    late Uri url;

    setUp(() async {
      final serverContext = SecurityContext()
        ..useCertificateChain(_certPath)
        ..usePrivateKey(_keyPath);
      server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4, 0, serverContext);
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        req.response.write('ok');
        await req.response.close();
      }));
      url = Uri.parse('https://localhost:${server.port}/pinned');
    });

    tearDown(() => server.close(force: true));

    test('the bad-certificate callback still fires, and its no still holds',
        () async {
      var asked = 0;
      final client = HttpClient()
        ..badCertificateCallback = (cert, host, port) {
          asked++;
          return false;
        };
      addTearDown(() => client.close(force: true));

      await expectLater(fetch(client, url), throwsA(isA<HandshakeException>()));
      expect(asked, 1,
          reason: 'a dropped callback fails the same way, silently — the '
              'count is what distinguishes threaded from bypassed');
    });

    test('the bad-certificate callback can still say yes', () async {
      final client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      addTearDown(() => client.close(force: true));

      await fetch(client, url);
      expect(records.single.statusCode, 200);
    });

    test('the TLS key log is threaded through the factory', () async {
      final lines = <String>[];
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) => true;
      client.keyLog = lines.add;
      addTearDown(() => client.close(force: true));

      await fetch(client, url);
      expect(lines, isNotEmpty,
          reason: 'the platform never reaches its own secure-socket call once '
              'a connection factory exists');
    });

    test(
      'the security context is threaded through the factory',
      () async {
        // Only this CA is trusted. If the factory dropped the context, the
        // platform default store would be used and this would not connect.
        final client = HttpClient(
          context: SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificates(_caPath),
        );
        addTearDown(() => client.close(force: true));

        await fetch(client, url);
        expect(records.single.statusCode, 200);
      },
      skip: Platform.isMacOS || Platform.isIOS
          ? 'Apple platforms delegate trust evaluation to the OS and ignore '
              'setTrustedCertificates (dart-lang/sdk#37812), so pinning there '
              'goes through badCertificateCallback — covered above. Runs on '
              'the Linux CI runner.'
          : null,
    );
  });
}
