// lib/src/managers/device_id_manager.dart

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'identity_format.dart';

/// Manages the persistent device identifier.
///
/// Format: `device_<epochMs>_<16hex>_<platform>`
/// Example: `device_1704067200000_a8b9c2d1e0f34567_android`
///
/// Stored in [FlutterSecureStorage] (Keychain on iOS — survives reinstall;
/// Android keystore accepts reset). Generated once on first launch, cached
/// in memory, and regenerated only if storage is empty or corrupted.
class DeviceIdManager {
  static const String _deviceIdKey = 'edge_telemetry_device_id';

  final FlutterSecureStorage _storage;
  String? _cachedDeviceId;

  DeviceIdManager({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Get or generate the device ID — stable across sessions and restarts.
  Future<String> getDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;

    try {
      final stored = await _storage.read(key: _deviceIdKey);
      if (stored != null && _isValidDeviceIdFormat(stored)) {
        _cachedDeviceId = stored;
        return stored;
      }
    } catch (e) {
      print('[DeviceIdManager] Failed to read from secure storage: $e');
    }

    _cachedDeviceId = _generateDeviceId();
    try {
      await _storage.write(key: _deviceIdKey, value: _cachedDeviceId);
    } catch (e) {
      // Keep the in-memory ID; retry persistence next session.
      print('[DeviceIdManager] Failed to persist device ID: $e');
    }
    return _cachedDeviceId!;
  }

  /// Format: `device_<epochMs>_<16hex>_<platform>`.
  String _generateDeviceId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'device_${timestamp}_${secureHex16()}_${platformTag()}';
  }

  /// Validates `device_<13-digit ts>_<random>_<platform>`, accepting both the
  /// legacy 8-alnum and new 16-hex random widths (see [isValidRandomPart]).
  bool _isValidDeviceIdFormat(String deviceId) {
    final parts = deviceId.split('_');
    if (parts.length != 4) return false;
    if (parts[0] != 'device') return false;
    if (parts[1].length != 13 || int.tryParse(parts[1]) == null) return false;
    if (!isValidRandomPart(parts[2])) return false;
    if (parts[3].isEmpty) return false;
    return true;
  }

  /// Clear the device ID from storage and memory (testing / device reset).
  Future<void> clearDeviceId() async {
    try {
      await _storage.delete(key: _deviceIdKey);
    } catch (e) {
      print('[DeviceIdManager] Failed to clear device ID: $e');
    }
    _cachedDeviceId = null;
  }

  /// True if a valid device ID is already persisted.
  Future<bool> hasStoredDeviceId() async {
    try {
      final stored = await _storage.read(key: _deviceIdKey);
      return stored != null && _isValidDeviceIdFormat(stored);
    } catch (e) {
      print('[DeviceIdManager] Failed to check stored device ID: $e');
      return false;
    }
  }
}
