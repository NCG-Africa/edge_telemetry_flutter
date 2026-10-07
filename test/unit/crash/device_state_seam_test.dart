import 'package:edge_telemetry_flutter/src/crash/native_crash_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The native seam for the device-state read (#91): one pull-only method on the
/// existing crash channel, a flat string map, omitted keys that stay omitted,
/// and a missing plugin that degrades to empty rather than throwing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeCrashChannel.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('missing plugin → empty map, never a throw', () async {
    // No handler registered: invokeMapMethod throws MissingPluginException.
    expect(await NativeCrashChannel().readDeviceState(), isEmpty);
  });

  test('null return → empty map', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await NativeCrashChannel().readDeviceState(), isEmpty);
  });

  test('the five fault-bundle keys arrive, coerced to strings', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readDeviceState');
      return <String, dynamic>{
        'device.battery_level': 87, // non-string coerced
        'device.battery_charging': false,
        'device.power_save_mode': true,
        'device.thermal_state': 'fair',
        'device.orientation': 'portrait',
        'memory.used_bytes': 14237696,
        'memory.source': 'pss',
      };
    });

    final state = await NativeCrashChannel().readDeviceState();
    expect(state['device.battery_level'], '87');
    expect(state['device.battery_charging'], 'false');
    expect(state['device.power_save_mode'], 'true');
    expect(state['device.thermal_state'], 'fair');
    expect(state['device.orientation'], 'portrait');
    expect(state['memory.used_bytes'], '14237696');
    expect(state['memory.source'], 'pss');
  });

  test('an omitted key stays omitted — never sentinelled', () async {
    // Android below API 29 has no thermal status; an iOS device flat on a desk
    // has no interface orientation worth reporting. Both are absences.
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, dynamic>{
        'device.battery_level': '41',
        'device.power_save_mode': 'false',
      };
    });

    final state = await NativeCrashChannel().readDeviceState();
    expect(state.containsKey('device.thermal_state'), isFalse);
    expect(state.containsKey('device.orientation'), isFalse);
    expect(state.containsKey('device.battery_charging'), isFalse);
    // And nothing was filled in with -1 / "unknown" on the way through.
    expect(state.values, isNot(contains('-1')));
    expect(state.values, isNot(contains('unknown')));
  });

  test(
    'a native read that throws degrades to empty, not to an app error',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'READ_FAILED'),
      );
      expect(await NativeCrashChannel().readDeviceState(), isEmpty);
    },
  );

  test(
    'the thermal vocabulary is the normalised string, not an ordinal',
    () async {
      // Android's 2 is MODERATE and iOS's 2 is serious — the ordinal means two
      // different things across the family, so only the name crosses the wire.
      for (final name in ['nominal', 'fair', 'serious', 'critical']) {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => <String, dynamic>{'device.thermal_state': name},
        );
        final state = await NativeCrashChannel().readDeviceState();
        expect(state['device.thermal_state'], name);
        expect(int.tryParse(state['device.thermal_state']!), isNull);
      }
    },
  );

  test('no cache: each call reads again', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return <String, dynamic>{'memory.used_bytes': '$calls'};
    });

    final first = await NativeCrashChannel().readDeviceState();
    final second = await NativeCrashChannel().readDeviceState();
    expect(first['memory.used_bytes'], '1');
    expect(second['memory.used_bytes'], '2');
    expect(calls, 2);
  });
}
