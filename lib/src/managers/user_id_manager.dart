// lib/src/managers/user_id_manager.dart

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_format.dart';

/// Manages the SDK-owned, anonymous user ID.
///
/// Format: `user_<epochMs>_<16hex>`. Generated once on first launch, persisted
/// across sessions, and stable across `identify()` / `setUserProfile()` — a new
/// ID only ever appears on reinstall.
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

  /// Format: `user_<epochMs>_<16hex>`.
  String _generateUserId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'user_${timestamp}_${secureHex16()}';
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
