// lib/src/managers/user_id_manager.dart

import 'package:shared_preferences/shared_preferences.dart';

/// Manages auto-generated user IDs with persistent storage
///
/// - Generates UUID on first app install
/// - Persists across app sessions
/// - New ID only on app reinstall
class UserIdManager {
  static const String _userIdKey = 'edge_telemetry_user_id';

  String? _currentUserId;
  SharedPreferences? _prefs;

  /// Get or generate user ID
  Future<String> getUserId() async {
    // Return cached ID if available
    if (_currentUserId != null) {
      return _currentUserId!;
    }

    // Initialize SharedPreferences if needed
    _prefs ??= await SharedPreferences.getInstance();

    // Try to get existing ID from storage
    _currentUserId = _prefs!.getString(_userIdKey);

    // Generate new ID if none exists
    if (_currentUserId == null) {
      _currentUserId = _generateUserId();
      await _prefs!.setString(_userIdKey, _currentUserId!);
    }

    return _currentUserId!;
  }

  /// Generate a unique user ID
  String _generateUserId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = _generateRandomString(8);
    return 'user_${timestamp}_$randomPart';
  }

  /// Generate random string for user ID uniqueness
  String _generateRandomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    var result = '';

    for (int i = 0; i < length; i++) {
      result += chars[(random + i) % chars.length];
    }

    return result;
  }

  /// Clear stored user ID (for testing purposes)
  Future<void> clearUserId() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_userIdKey);
    _currentUserId = null;
  }

  /// Check if user ID exists in storage
  Future<bool> hasStoredUserId() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!.containsKey(_userIdKey);
  }
}
