// test/integration/contract_v4_envelope_test.dart
//
// Contract 4.0.0 (#116), asserted on the JSON that leaves the device: the real
// `EdgeTelemetry.initialize()` → public tracking API → real `RetryTransport`
// POST to a loopback server, decoded from the bytes it received. No sender seam
// and no hand-wired stack, so what is asserted is what a collector would see.
//
// Platform plugins are mocked at their boundary (package info, secure storage,
// path provider, connectivity, the native crash channel); everything between
// the public API and the socket is the shipped code.

import 'dart:convert';
import 'dart:io';

import 'package:edge_telemetry_flutter/edge_telemetry_flutter.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/core/sdk_version.dart';
import 'package:edge_telemetry_flutter/src/crash/native_crash_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_identity.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// A loopback collector: records every decoded batch body.
class _Collector {
  final List<Map<String, dynamic>> batches = [];
  late HttpServer _server;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final raw = await req.fold<List<int>>([], (a, c) => a..addAll(c));
      final plain =
          req.headers.value('Content-Encoding') == 'gzip'
              ? gzip.decode(raw)
              : raw;
      batches.add(jsonDecode(utf8.decode(plain)) as Map<String, dynamic>);
      await req.response.close();
    });
    return 'http://${_server.address.host}:${_server.port}';
  }

  Future<void> stop() => _server.close(force: true);

  Iterable<Map<String, dynamic>> get items =>
      batches.expand((b) => (b['events'] as List).cast<Map<String, dynamic>>());

  /// Wait (real time) until an item named [name] has arrived.
  Future<void> waitFor(String name) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!items.any((i) => i['eventName'] == name)) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'no "$name" item arrived; got ${items.map((i) => i['eventName'])}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const nativeChannel = MethodChannel(NativeCrashChannel.channelName);

  late _Collector collector;
  late String endpoint;
  late List<Map<String, String>> nativeCrashes;

  void mockPackageInfo({String version = '1.4.2', String build = '142'}) =>
      PackageInfo.setMockInitialValues(
        appName: 'Client App',
        packageName: 'com.client.app',
        version: version,
        buildNumber: build,
        buildSignature: '',
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    mockPackageInfo();
    final docs = await Directory.systemTemp.createTemp('contract_v4_');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    RetryTransport.resetGzipProbe();
    nativeCrashes = [];

    messenger.setMockMethodCallHandler(
      nativeChannel,
      (call) async =>
          call.method == 'drainNativeCrashes' ? nativeCrashes : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
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
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        null,
      );
    });

    collector = _Collector();
    endpoint = await collector.start();
    addTearDown(collector.stop);
  });

  Future<void> init({Map<String, String>? globals}) => EdgeTelemetry.initialize(
    endpoint: endpoint,
    serviceName: 'contract-v4-test',
    apiKey: 'edge_test_key',
    batchSize: 1,
    globalAttributes: globals,
  );

  test(
    'the envelope on the wire is contract 4.0.0 (R1–R3, R5, R6, R13, S1)',
    () async {
      await init(globals: {'app.version': '9.9.9', 'team': 'core'});
      EdgeTelemetry.instance.trackEvent('checkout', attributes: {'step': 2});
      await collector.waitFor('custom_event');

      expect(collector.batches, isNotEmpty);
      for (final batch in collector.batches) {
        // Exactly the eight R3 keys, in order — no clock_skew_ms, no context.
        expect(batch.keys.toList(), kR3EnvelopeKeys);
        expect(batch['type'], 'telemetry_batch');
        expect(batch['contract_version'], '4.0.0');
        expect(batch['sdk'], {'name': 'flutter', 'version': kSdkVersion});
        // Captured once at init from PackageInfo + the OS; a consumer global
        // named app.version does not override it.
        expect(batch['app'], {
          'name': 'Client App',
          'package_name': 'com.client.app',
          'platform': 'android', // flutter_test's defaultTargetPlatform
          'version': '1.4.2',
          'build_number': '142',
        });
        expect(batch['device_id'], isA<String>());
        expect(batch['device_id'] as String, isNotEmpty);
        expect(batch['batch_size'], (batch['events'] as List).length);
        // UTC RFC 3339 with Z, stamped at send.
        final ts = batch['timestamp'] as String;
        expect(ts, endsWith('Z'));
        expect(
          DateTime.parse(ts).difference(DateTime.now().toUtc()).abs(),
          lessThan(const Duration(seconds: 10)),
        );
      }

      // One device, one id, every batch.
      expect(
        collector.batches.map((b) => b['device_id']).toSet(),
        hasLength(1),
      );

      for (final item in collector.items) {
        final attrs = item['attributes'] as Map<String, dynamic>;
        // No per-item identity copies (R1).
        expect(
          attrs.keys.where(
            (k) =>
                k == 'device.id' ||
                k.startsWith('app.') ||
                k.startsWith('sdk.'),
          ),
          isEmpty,
          reason: '${item['eventName']} carries identity',
        );
        // Context rides each item (R6), and so does the seam state (R1).
        expect(attrs['user.id'], isNotNull);
        expect(attrs['device.platform'], isNotNull);
        expect(attrs['http_seam_state'], isNotNull);
      }

      final event = collector.items.firstWhere(
        (i) => i['eventName'] == 'custom_event',
      );
      final attrs = event['attributes'] as Map;
      expect(attrs['event.name'], 'checkout');
      expect(attrs['step'], '2');
      expect(attrs['team'], 'core'); // a non-identity global still rides
      expect(attrs['session.id'], isNotNull); // session context, per item
    },
  );

  test(
    'an empty PackageInfo version / build_number is omitted (R15)',
    () async {
      mockPackageInfo(version: '', build: '');
      await init();
      await collector.waitFor('session.started');

      final app = collector.batches.first['app'] as Map;
      expect(app.containsKey('version'), isFalse);
      expect(app.containsKey('build_number'), isFalse);
      expect(app['package_name'], 'com.client.app');
    },
  );
}
