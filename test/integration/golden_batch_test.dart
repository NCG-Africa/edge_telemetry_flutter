// test/integration/golden_batch_test.dart
//
// Golden batches (#127, #135): every catalogue event this SDK emits, recorded
// through the real `EdgeTelemetry.initialize()` → public API → real
// `RetryTransport` POST to a loopback server. Every POSTed batch is dumped raw
// to the gitignored `test/raw/`. `scripts/conform.sh` runs the processor's
// `cmd/conform` on it at the tag pinned in `catalogue.version`: catalogue
// check, then the derived shape (event, key, type; no values) must equal the
// committed `test/shape.txt`. Nothing here compares values.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:edge_telemetry_flutter/edge_telemetry_flutter.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/crash/native_crash_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dumps the real wire to test/raw', (tester) async {
    // Real sockets and timers: everything runs outside the fake clock.
    await tester.runAsync(() => _record(binding));
  });
}

Future<void> _record(TestWidgetsFlutterBinding binding) async {
  final messenger = binding.defaultBinaryMessenger;
  const nativeChannel = MethodChannel(NativeCrashChannel.channelName);
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const connectivityStatus = 'dev.fluttercommunity.plus/connectivity_status';
  {
    // A session left open by a killed process: recovered at init, with one
    // task still open, so the finalize and the abandoned task are real.
    final before = DateTime.now().subtract(const Duration(hours: 1));
    SharedPreferences.setMockInitialValues({
      // The previous launch's build, which a drained native crash reports.
      'edge_telemetry_last_app': jsonEncode({
        'name': 'Golden App',
        'package_name': 'com.example.golden',
        'platform': 'android',
        'version': '0.9.0',
        'build_number': '0',
      }),
      'edge_telemetry_session_record': jsonEncode({
        'id': 'session_old',
        'start': before.toIso8601String(),
        'lastActivity':
            before.add(const Duration(minutes: 5)).toIso8601String(),
        'screenCount': 1,
        'journey': ['/home'],
        'tasks': {
          'checkout': {'start': before.toIso8601String()},
        },
      }),
    });
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Golden App',
      packageName: 'com.example.golden',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final docs = await Directory.systemTemp.createTemp('golden_');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    RetryTransport.resetGzipProbe();

    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      switch (call.method) {
        case 'processUptimeMs':
          return 850;
        case 'readDeviceState':
          return {'memory.used_bytes': '104857600', 'memory.source': 'pss'};
        case 'drainNativeCrashes':
          // The plugins' own payloads, pre-catalogue keys and all.
          const fault = {
            'device.battery_level': '80',
            'device.battery_charging': 'false',
            'device.power_save_mode': 'false',
            'device.thermal_state': 'none',
            'device.orientation': 'portrait',
            'native_capture_tier': 'exit_info',
          };
          return [
            {
              'message': 'boom',
              'stacktrace': 'java.lang.IllegalStateException: boom',
              'exception_type': 'java.lang.IllegalStateException',
              'cause': 'NativeCrash',
              'is_fatal': 'true',
              'crash.source': 'uncaught_handler',
              ...fault,
            },
            {
              'message': 'Input dispatching timed out',
              'stacktrace': '"main" prio=5 tid=1 Blocked',
              'exception_type': 'ANR',
              'cause': 'ANR',
              'is_fatal': 'true',
              'crash.source': 'app_exit_info',
              ...fault,
            },
            {
              'hang.duration_ms': '2500',
              'message': 'app hang 2.5s',
              'stacktrace': '{}',
              'exception_type': 'MXHangDiagnostic',
              'cause': 'Hang',
              'is_fatal': 'true',
              'crash.source': 'metrickit',
            },
          ];
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      connectivity,
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(connectivityStatus),
      (call) async => null,
    );

    // The collector: records every POSTed batch; answers anything else empty.
    final batches = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await req.fold<List<int>>([], (a, c) => a..addAll(c));
      if (req.method == 'POST' && req.uri.path == '/collector') {
        final plain =
            req.headers.value('Content-Encoding') == 'gzip'
                ? gzip.decode(raw)
                : raw;
        batches.add(jsonDecode(utf8.decode(plain)) as Map<String, dynamic>);
      }
      await req.response.close();
    });
    final base = 'http://${server.address.host}:${server.port}';

    final bindingOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final onError = FlutterError.onError;
    final dispatcherOnError = PlatformDispatcher.instance.onError;
    Future<void> restore() async {
      EdgeTelemetry.instance.dispose();
      FlutterError.onError = onError;
      PlatformDispatcher.instance.onError = dispatcherOnError;
      HttpOverrides.global = bindingOverrides;
      messenger.setMockMethodCallHandler(nativeChannel, null);
      messenger.setMockMethodCallHandler(connectivity, null);
      await server.close(force: true);
    }

    await EdgeTelemetry.initialize(
      endpoint: '$base/collector',
      serviceName: 'golden',
      apiKey: 'edge_golden_key',
      batchSize: 1,
      tier: CollectionTier.diagnostic,
    );
    final t = EdgeTelemetry.instance;

    void frame() {
      binding.handleBeginFrame(null);
      binding.handleDrawFrame();
    }

    // app.start ends at the first frame.
    frame();

    // Navigation: the first screen, then a push after it painted.
    final observer = t.navigationObserver;
    final home = MaterialPageRoute<void>(
      builder: (_) => const SizedBox(),
      settings: const RouteSettings(name: '/home'),
    );
    observer.didPush(home, null);
    frame();
    t.reportScreenSettled();
    observer.didPush(
      MaterialPageRoute<void>(
        builder: (_) => const SizedBox(),
        settings: const RouteSettings(name: '/orders/42', arguments: 1),
      ),
      home,
    );

    // A tap.
    final router = GestureBinding.instance.pointerRouter;
    router.route(const PointerDownEvent(pointer: 7, position: Offset(10, 10)));
    router.route(const PointerUpEvent(pointer: 7, position: Offset(10, 10)));

    // Frames: one slow, one frozen. The window flushes on pause.
    PlatformDispatcher.instance.onReportTimings?.call([
      for (final ms in [8, 30, 720])
        FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: ms * 500,
          rasterStart: ms * 500,
          rasterFinish: ms * 1000,
          rasterFinishWallTime: ms * 1000,
        ),
    ]);

    // HTTP through the installed capture seam.
    final client = HttpClient();
    final res = await (await client.getUrl(Uri.parse('$base/api/7'))).close();
    await res.drain<void>();
    client.close();

    t.trackEvent('checkout_started');
    t.trackMetric('cart_value', 12.5);
    t.trackError(StateError('handled'), stackTrace: StackTrace.current);
    PlatformDispatcher.instance.onError!(
      StateError('unhandled'),
      StackTrace.current,
    );
    t.startTask('pay');
    t.completeTask('pay');
    t.setUserProfile(name: 'Ada', email: 'ada@example.com');

    // Connectivity drops: one network.change.
    await messenger.handlePlatformMessage(
      connectivityStatus,
      const StandardMethodCodec().encodeSuccessEnvelope(<String>['mobile']),
      (_) {},
    );

    // Background: app.lifecycle, the session-end memory read, frame flush.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

    // Let the async sends land.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await restore();

    expect(batches, isNotEmpty);
    final raw = Directory('test/raw');
    if (raw.existsSync()) raw.deleteSync(recursive: true);
    raw.createSync(recursive: true);
    for (final (i, b) in batches.indexed) {
      File('test/raw/batch-$i.json').writeAsStringSync(jsonEncode(b));
    }
  }
}
