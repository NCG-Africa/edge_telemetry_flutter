// test/integration/failed_send_policy_test.dart
//
// Where a batch goes and what happens when the collector refuses it (#118: R10,
// R12, R13, R14), driven through the real `EdgeTelemetry.initialize()` → public
// tracking API → real `RetryTransport` POST to a loopback collector that
// answers with scripted statuses. "Queued" is read off the offline queue's
// directory on disk, so nothing here asserts on a seam the SDK doesn't ship.

import 'dart:convert';
import 'dart:io';

import 'package:edge_telemetry_flutter/edge_telemetry_flutter.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/crash/native_crash_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// What the stub answers one batch with: an HTTP status (plus an optional
/// `Retry-After`), or [hangUp] for a connection dropped mid-request.
typedef Reply = ({int status, String? retryAfter});

const Reply ok = (status: 200, retryAfter: null);
const Reply hangUp = (status: -1, retryAfter: null);
Reply status(int code, {String? retryAfter}) => (
  status: code,
  retryAfter: retryAfter,
);

/// A loopback collector at a full path. [script] picks the reply per batch; it
/// can be swapped mid-test (an outage ending). Every attempt is recorded,
/// delivered or not, with its path and arrival time.
class _Stub {
  _Stub(this.path);
  final String path;
  Reply Function(Map<String, dynamic> batch) script = (_) => ok;

  final List<({String path, Map<String, dynamic> batch, DateTime at})>
  attempts = [];
  final List<Map<String, dynamic>> delivered = [];
  late HttpServer _server;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final raw = await req.fold<List<int>>([], (a, c) => a..addAll(c));
      final plain =
          req.headers.value('Content-Encoding') == 'gzip'
              ? gzip.decode(raw)
              : raw;
      final batch = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      attempts.add((path: req.uri.path, batch: batch, at: DateTime.now()));
      final reply = script(batch);
      if (reply.status == hangUp.status) {
        (await req.response.detachSocket()).destroy();
        return;
      }
      if (reply.status < 300) delivered.add(batch);
      req.response.statusCode = reply.status;
      if (reply.retryAfter != null) {
        req.response.headers.set('Retry-After', reply.retryAfter!);
      }
      await req.response.close();
    });
    return 'http://${_server.address.host}:${_server.port}$path';
  }

  Future<void> stop() => _server.close(force: true);
}

/// The names of the items in [batch].
List<String> names(Map<String, dynamic> batch) => [
  for (final e in batch['events'] as List)
    ((e as Map)['eventName'] ?? e['metricName']) as String,
];

/// The `event.name` of a `custom_event` batch (`trackEvent('x')` → `x`).
String? customName(Map<String, dynamic> batch) {
  for (final e in batch['events'] as List) {
    if ((e as Map)['eventName'] == 'custom_event') {
      return (e['attributes'] as Map)['event.name'] as String?;
    }
  }
  return null;
}

Future<void> until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const nativeChannel = MethodChannel(NativeCrashChannel.channelName);
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');

  late _Stub stub;
  late String endpoint;
  late Directory queueDir;
  late List<Map<String, String>> nativeCrashes;

  /// Queued files, oldest first within each prefix.
  List<String> queued() =>
      queueDir.existsSync()
          ? (queueDir.listSync().map((f) => f.uri.pathSegments.last).toList()
            ..sort())
          : [];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Client App',
      packageName: 'com.client.app',
      version: '4.0',
      buildNumber: '40',
      buildSignature: '',
    );
    final docs = await Directory.systemTemp.createTemp('failed_send_');
    queueDir = Directory('${docs.path}/edge_telemetry_queue');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    RetryTransport.resetGzipProbe();
    // The real schedule is 40 s of waiting; the shape (4 attempts) is what's
    // under test, not the seconds.
    RetryTransport.defaultBackoff = const [
      Duration.zero,
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
    ];
    addTearDown(() => RetryTransport.defaultBackoff = kDefaultBackoff);
    nativeCrashes = [];

    messenger.setMockMethodCallHandler(
      nativeChannel,
      (call) async =>
          call.method == 'drainNativeCrashes' ? nativeCrashes : null,
    );
    messenger.setMockMethodCallHandler(
      connectivity,
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );

    // The test binding answers every real HttpClient with a 400; these tests
    // need the socket. `initialize` installs its own capture override on top.
    final bindingOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final onError = FlutterError.onError;
    final dispatcherOnError = PlatformDispatcher.instance.onError;
    addTearDown(() {
      EdgeTelemetry.instance.dispose();
      FlutterError.onError = onError;
      PlatformDispatcher.instance.onError = dispatcherOnError;
      HttpOverrides.global = bindingOverrides;
      messenger.setMockMethodCallHandler(nativeChannel, null);
      messenger.setMockMethodCallHandler(connectivity, null);
    });

    stub = _Stub('/collector-go/telemetry');
    endpoint = await stub.start();
    addTearDown(stub.stop);
  });

  /// Initialize, then let the launch's own batches land: every success
  /// drains the queue, so a probe tracked before they settle would be
  /// re-POSTed by a drain and its attempt count would mean nothing.
  Future<void> init() async {
    await EdgeTelemetry.initialize(
      endpoint: endpoint,
      serviceName: 'failed-send-test',
      apiKey: 'edge_test_key',
      batchSize: 1,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  test('posts to the configured URL exactly as given, appending nothing, '
      'and never reports its own upload (R10)', () async {
    await init();
    EdgeTelemetry.instance.trackEvent('probe');
    await until(
      () => stub.delivered.any((b) => customName(b) == 'probe'),
      'probe',
    );

    expect(stub.attempts.map((a) => a.path).toSet(), {
      '/collector-go/telemetry',
    });
    // The capture hook excludes the configured URL: no item describes the
    // SDK's own POST.
    expect(stub.delivered.expand(names), isNot(contains('http.request')));
  });

  /// The custom-event names held in the queue files on disk, oldest first. A
  /// file still being written is skipped; the next poll sees it whole.
  List<String?> queuedNames() => [
    for (final f in queued())
      ...() {
        try {
          return [
            customName(
              jsonDecode(File('${queueDir.path}/$f').readAsStringSync())
                  as Map<String, dynamic>,
            ),
          ];
        } on FormatException {
          return const <String?>[];
        }
      }(),
  ];

  List<String?> attemptsAt(String name) => [
    for (final a in stub.attempts)
      if (customName(a.batch) == name) name,
  ];

  group('R12: retryable — retried, then queued offline', () {
    for (final (label, reply, tries) in [
      ('429', status(429), 4),
      ('500', status(500), 4),
      ('503', status(503), 4),
      // A network error learns nothing from more attempts: queued at once.
      ('a dropped connection', hangUp, 1),
    ]) {
      test(label, () async {
        stub.script = (b) => customName(b) == 'probe' ? reply : ok;
        await init();
        EdgeTelemetry.instance.trackEvent('probe');
        await until(() => queuedNames().contains('probe'), 'probe queued');

        expect(attemptsAt('probe'), hasLength(tries));
        expect(stub.delivered.map(customName), isNot(contains('probe')));
      });
    }
  });

  for (final code in [401, 404]) {
    test(
      'R12: a $code is dropped after one attempt and never queued',
      () async {
        stub.script = (b) => customName(b) == 'probe' ? status(code) : ok;
        await init();
        EdgeTelemetry.instance.trackEvent('probe');
        EdgeTelemetry.instance.trackEvent('after');
        await until(
          () => stub.delivered.any((b) => customName(b) == 'after'),
          'after',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(attemptsAt('probe'), hasLength(1));
        expect(queued(), isEmpty);
      },
    );
  }

  test('R12: a 401 at the head of the queue never blocks the batches behind '
      'it', () async {
    // An outage queues a, b, c; when it ends, the collector refuses a.
    stub.script = (b) => customName(b) == null ? ok : status(503);
    await init();
    for (final name in ['a', 'b', 'c']) {
      EdgeTelemetry.instance.trackEvent(name);
      await until(() => queuedNames().contains(name), '$name queued');
    }

    stub.script = (b) => customName(b) == 'a' ? status(401) : ok;
    EdgeTelemetry.instance.trackEvent('d'); // a success triggers the drain
    await until(() => queued().isEmpty, 'queue drained');

    expect(stub.delivered.map(customName).whereType<String>().toList(), [
      'd',
      'b',
      'c',
    ]);
  });
}
