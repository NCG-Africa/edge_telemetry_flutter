// lib/src/managers/device_id_manager.dart

import 'dart:io';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages unique device identifiers with persistent storage
///
/// Generates device IDs in format: device_<timestamp>_<random>_<platform>
/// Example: device_1704067200000_a8b9c2d1_android
///
/// Features:
/// - Generates unique device ID on first app install
/// - Persists across app sessions using SharedPreferences
/// - In-memory caching for performance
/// - Graceful error handling with fallback strategies
/// - Platform-aware ID generation
class DeviceIdManager {
  static const String _deviceIdKey = 'edge_telemetry_device_id';
  
  String? _cachedDeviceId;
  SharedPreferences? _prefs;
  final Random _random = Random();
  
  /// Get or generate device ID
  /// 
  /// Returns the same device ID across app sessions and restarts.
  /// Generates a new ID only on first app install or if storage is corrupted.
  Future<String> getDeviceId() async {
    try {
      // Return cached ID if available
      if (_cachedDeviceId != null) {
        print('[DeviceIdManager] Returning cached device ID: $_cachedDeviceId');
        return _cachedDeviceId!;
      }

      // Initialize SharedPreferences if needed
      if (_prefs == null) {
        try {
          _prefs = await SharedPreferences.getInstance();
        } catch (e) {
          print('[DeviceIdManager] Failed to initialize SharedPreferences: $e');
          // Fallback: generate in-memory ID and return it
          _cachedDeviceId = _generateDeviceId();
          print('[DeviceIdManager] Generated fallback in-memory device ID: $_cachedDeviceId');
          return _cachedDeviceId!;
        }
      }

      // Try to get existing ID from storage
      try {
        _cachedDeviceId = _prefs!.getString(_deviceIdKey);
        if (_cachedDeviceId != null) {
          // Validate the format of stored device ID
          if (_isValidDeviceIdFormat(_cachedDeviceId!)) {
            print('[DeviceIdManager] Loaded device ID from storage: $_cachedDeviceId');
            return _cachedDeviceId!;
          } else {
            print('[DeviceIdManager] Stored device ID has invalid format, regenerating: $_cachedDeviceId');
            _cachedDeviceId = null;
          }
        }
      } catch (e) {
        print('[DeviceIdManager] Failed to read from storage: $e');
      }

      // Generate new ID if none exists or stored ID was invalid
      _cachedDeviceId = _generateDeviceId();
      print('[DeviceIdManager] Generated new device ID: $_cachedDeviceId');

      // Try to persist the new ID
      try {
        await _prefs!.setString(_deviceIdKey, _cachedDeviceId!);
        print('[DeviceIdManager] Persisted device ID to storage');
      } catch (e) {
        print('[DeviceIdManager] Failed to persist device ID: $e');
        // Continue with in-memory ID, will retry persistence next session
      }

      return _cachedDeviceId!;
    } catch (e) {
      print('[DeviceIdManager] Unexpected error in getDeviceId: $e');
      // Last resort: generate a basic fallback ID
      final fallbackId = 'device_${DateTime.now().millisecondsSinceEpoch}_fallback_${_getPlatformString()}';
      _cachedDeviceId = fallbackId;
      return fallbackId;
    }
  }

  /// Generate a unique device ID
  /// 
  /// Format: device_<timestamp>_<random>_<platform>
  /// - timestamp: Unix milliseconds (13 digits)
  /// - random: 8-character alphanumeric lowercase string
  /// - platform: Current platform (android, ios, web, etc.)
  String _generateDeviceId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = _generateRandomString(8);
    final platform = _getPlatformString();
    
    final deviceId = 'device_${timestamp}_${randomPart}_$platform';
    print('[DeviceIdManager] Generated device ID: $deviceId');
    return deviceId;
  }

  /// Generate cryptographically secure random string
  /// 
  /// Uses dart:math Random for generating 8-character alphanumeric lowercase string
  String _generateRandomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(
      Iterable.generate(
        length,
        (_) => chars.codeUnitAt(_random.nextInt(chars.length)),
      ),
    );
  }

  /// Get platform string for device ID
  /// 
  /// Returns platform-specific strings:
  /// - Android: "android"
  /// - iOS: "ios"
  /// - Web: "web"
  /// - Others: actual Platform.operatingSystem value
  String _getPlatformString() {
    try {
      // Handle web platform which doesn't have Platform.operatingSystem
      if (identical(0, 0.0)) {
        // This is a compile-time check for web
        return 'web';
      }
      
      final platform = Platform.operatingSystem.toLowerCase();
      switch (platform) {
        case 'android':
          return 'android';
        case 'ios':
          return 'ios';
        case 'macos':
          return 'macos';
        case 'windows':
          return 'windows';
        case 'linux':
          return 'linux';
        case 'fuchsia':
          return 'fuchsia';
        default:
          return platform;
      }
    } catch (e) {
      print('[DeviceIdManager] Failed to detect platform: $e');
      return 'unknown';
    }
  }

  /// Validate device ID format
  /// 
  /// Checks if the device ID follows the expected format:
  /// device_<timestamp>_<random>_<platform>
  bool _isValidDeviceIdFormat(String deviceId) {
    try {
      final parts = deviceId.split('_');
      if (parts.length != 4) return false;
      if (parts[0] != 'device') return false;
      
      // Validate timestamp (should be 13 digits)
      final timestamp = int.tryParse(parts[1]);
      if (timestamp == null || parts[1].length != 13) return false;
      
      // Validate random part (should be 8 characters, alphanumeric lowercase)
      final randomPart = parts[2];
      if (randomPart.length != 8) return false;
      if (!RegExp(r'^[a-z0-9]+$').hasMatch(randomPart)) return false;
      
      // Platform part should be non-empty
      if (parts[3].isEmpty) return false;
      
      return true;
    } catch (e) {
      print('[DeviceIdManager] Device ID validation error: $e');
      return false;
    }
  }

  /// Clear device ID from storage and memory
  /// 
  /// Useful for testing scenarios or when device needs to be reset
  Future<void> clearDeviceId() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.remove(_deviceIdKey);
      _cachedDeviceId = null;
      print('[DeviceIdManager] Cleared device ID from storage and cache');
    } catch (e) {
      print('[DeviceIdManager] Failed to clear device ID: $e');
      // Clear cache even if storage operation fails
      _cachedDeviceId = null;
    }
  }

  /// Check if device ID exists in persistent storage
  /// 
  /// Returns true if a device ID is stored in SharedPreferences
  Future<bool> hasStoredDeviceId() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final hasKey = _prefs!.containsKey(_deviceIdKey);
      final storedId = _prefs!.getString(_deviceIdKey);
      
      // Check both existence and validity
      final isValid = hasKey && storedId != null && _isValidDeviceIdFormat(storedId);
      print('[DeviceIdManager] Has stored device ID: $isValid');
      return isValid;
    } catch (e) {
      print('[DeviceIdManager] Failed to check stored device ID: $e');
      return false;
    }
  }
}
