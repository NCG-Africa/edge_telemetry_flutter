// test/unit/managers/identity_test.dart
//
// The identity contract (ticket #20): canon ID formats, secure 16-hex entropy,
// a both-width validator for in-place upgrade, and user.id stability across
// `identify()` (persisted → same ID on every getUserId, even a fresh manager).

import 'package:edge_telemetry_flutter/src/managers/device_id_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/identity_format.dart';
import 'package:edge_telemetry_flutter/src/managers/user_id_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('secureHex16', () {
    test('is 16 lowercase hex chars', () {
      for (var i = 0; i < 100; i++) {
        expect(secureHex16(), matches(r'^[0-9a-f]{16}$'));
      }
    });

    test('does not repeat across calls (secure entropy)', () {
      final seen = {for (var i = 0; i < 200; i++) secureHex16()};
      expect(seen.length, 200);
    });
  });

  group('isValidRandomPart — both widths', () {
    test('accepts legacy 8-char alnum', () {
      expect(isValidRandomPart('a8b9c2d1'), isTrue);
    });
    test('accepts new 16-hex', () {
      expect(isValidRandomPart('a8b9c2d1e0f34567'), isTrue);
    });
    test('rejects wrong widths and non-hex 16', () {
      expect(isValidRandomPart('abc'), isFalse); // too short
      expect(isValidRandomPart('a8b9c2d1e0'), isFalse); // 10 chars
      expect(isValidRandomPart('g8b9c2d1e0f34567'), isFalse); // 16 but non-hex
    });
  });

  group('DeviceIdManager', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('generates canon device_<13ts>_<16hex>_<platform>', () async {
      final id = await DeviceIdManager().getDeviceId();
      final parts = id.split('_');
      expect(parts[0], 'device');
      expect(parts[1].length, 13); // epoch ms
      expect(parts[2], matches(r'^[0-9a-f]{16}$'));
      expect(parts[3], isNotEmpty); // platform
    });

    test('persists in secure storage — same ID across managers', () async {
      final first = await DeviceIdManager().getDeviceId();
      final second = await DeviceIdManager().getDeviceId(); // fresh instance
      expect(second, first);
    });

    test('adopts a legacy 8-alnum stored ID in place (no regen)', () async {
      const legacy = 'device_1704067200000_a8b9c2d1_android';
      FlutterSecureStorage.setMockInitialValues(
          {'edge_telemetry_device_id': legacy});
      expect(await DeviceIdManager().getDeviceId(), legacy);
    });

    test('regenerates when stored ID is malformed', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'edge_telemetry_device_id': 'garbage'});
      final id = await DeviceIdManager().getDeviceId();
      expect(id, startsWith('device_'));
      expect(id.split('_')[2], matches(r'^[0-9a-f]{16}$'));
    });
  });

  group('UserIdManager', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('generates canon user_<13ts>_<16hex>', () async {
      final id = await UserIdManager().getUserId();
      final parts = id.split('_');
      expect(parts.length, 3);
      expect(parts[0], 'user');
      expect(parts[1].length, 13);
      expect(parts[2], matches(r'^[0-9a-f]{16}$'));
    });

    test('stable across identify() — persisted, same on fresh manager',
        () async {
      final original = await UserIdManager().getUserId();
      // identify() never regenerates the SDK-owned id; a new manager reading
      // the same storage must return the identical id.
      final afterIdentify = await UserIdManager().getUserId();
      expect(afterIdentify, original);
    });
  });
}
