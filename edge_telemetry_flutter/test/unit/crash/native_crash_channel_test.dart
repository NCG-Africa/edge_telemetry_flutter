import 'package:edge_telemetry_flutter/src/crash/native_crash_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeCrashChannel.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('no native plugin registered → empty list (safe no-op)', () async {
    // No handler set: invokeMethod throws MissingPluginException.
    expect(await NativeCrashChannel().drainNativeCrashes(), isEmpty);
  });

  test('parses native payloads to List<Map<String,String>>', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'drainNativeCrashes');
      return <dynamic>[
        {
          'message': 'SIGSEGV',
          'stacktrace': 'frame0\nframe1',
          'exception_type': 'EXC_BAD_ACCESS',
          'cause': 'NativeCrash',
          'is_fatal': true, // non-string coerced to "true"
          'crash.source': 'metrickit',
        },
      ];
    });

    final crashes = await NativeCrashChannel().drainNativeCrashes();
    expect(crashes, hasLength(1));
    expect(crashes.first['cause'], 'NativeCrash');
    expect(crashes.first['is_fatal'], 'true');
    expect(crashes.first['crash.source'], 'metrickit');
  });

  test('null return → empty list', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await NativeCrashChannel().drainNativeCrashes(), isEmpty);
  });
}
