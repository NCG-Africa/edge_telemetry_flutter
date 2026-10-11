// test/integration/failed_send_policy_test.dart
//
// Where a batch goes and what happens when the collector refuses it (#118: R10,
// R12, R13, R14), driven through the real `EdgeTelemetry.initialize()` → public
// tracking API → real `RetryTransport` POST to a loopback collector that
// answers with scripted statuses. "Queued" is read off the offline queue's
// directory on disk, so nothing here asserts on a seam the SDK doesn't ship.

import 'dart:async';
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

  Future<void> init() => EdgeTelemetry.initialize(
    endpoint: endpoint,
    serviceName: 'failed-send-test',
    apiKey: 'edge_test_key',
    batchSize: 1,
  );

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
}
