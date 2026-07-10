// lib/src/managers/user_profile_manager.dart

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages user profile information with persistent storage
///
/// - Stores user profile data (name, email, phone, custom attributes)
/// - Persists across app sessions
/// - Provides methods to set, update, clear, and retrieve profile data
class UserProfileManager {
  static const String _profileKey = 'edge_telemetry_user_profile';
  
  Map<String, String> _currentProfile = {};
  SharedPreferences? _prefs;
  bool _isLoaded = false;

  /// Get current user profile data
  Future<Map<String, String>> getProfile() async {
    if (!_isLoaded) {
      await _loadProfile();
    }
    return Map.unmodifiable(_currentProfile);
  }

  /// Set user profile information
  /// 
  /// [name] - User's display name
  /// [email] - User's email address  
  /// [phone] - User's phone number
  /// [customAttributes] - Additional custom profile attributes
  /// [merge] - If true, merge with existing profile. If false, replace completely
  Future<void> setProfile({
    String? name,
    String? email,
    String? phone,
    Map<String, String>? customAttributes,
    bool merge = true,
  }) async {
    await _ensureLoaded();

    if (!merge) {
      _currentProfile.clear();
    }

    // Set standard profile fields
    if (name != null) _currentProfile['user.name'] = name;
    if (email != null) _currentProfile['user.email'] = email;
    if (phone != null) _currentProfile['user.phone'] = phone;

    // Add custom attributes
    if (customAttributes != null) {
      for (final entry in customAttributes.entries) {
        // Ensure custom attributes have proper prefix
        final key = entry.key.startsWith('user.') ? entry.key : 'user.${entry.key}';
        _currentProfile[key] = entry.value;
      }
    }

    // Add metadata
    _currentProfile['user.profile_updated_at'] = DateTime.now().toIso8601String();

    await _saveProfile();
  }

  /// Update specific profile fields without clearing others
  Future<void> updateProfile({
    String? name,
    String? email,
    String? phone,
    Map<String, String>? customAttributes,
  }) async {
    await setProfile(
      name: name,
      email: email,
      phone: phone,
      customAttributes: customAttributes,
      merge: true,
    );
  }

  /// Clear all profile data
  Future<void> clearProfile() async {
    await _ensureLoaded();
    _currentProfile.clear();
    await _saveProfile();
  }

  /// Remove specific profile field
  Future<void> removeField(String key) async {
    await _ensureLoaded();
    final profileKey = key.startsWith('user.') ? key : 'user.$key';
    _currentProfile.remove(profileKey);
    await _saveProfile();
  }

  /// Check if profile has any data
  Future<bool> hasProfile() async {
    final profile = await getProfile();
    return profile.isNotEmpty;
  }

  /// Check if specific field exists
  Future<bool> hasField(String key) async {
    final profile = await getProfile();
    final profileKey = key.startsWith('user.') ? key : 'user.$key';
    return profile.containsKey(profileKey);
  }

  /// Get profile summary for debugging
  Future<Map<String, dynamic>> getProfileSummary() async {
    final profile = await getProfile();
    return {
      'has_profile': profile.isNotEmpty,
      'field_count': profile.length,
      'has_name': profile.containsKey('user.name'),
      'has_email': profile.containsKey('user.email'),
      'has_phone': profile.containsKey('user.phone'),
      'custom_fields': profile.keys
          .where((k) => !['user.name', 'user.email', 'user.phone', 'user.profile_updated_at'].contains(k))
          .length,
      'last_updated': profile['user.profile_updated_at'],
    };
  }

  /// Load profile from persistent storage
  Future<void> _loadProfile() async {
    _prefs ??= await SharedPreferences.getInstance();
    
    final profileJson = _prefs!.getString(_profileKey);
    if (profileJson != null) {
      try {
        final decoded = json.decode(profileJson) as Map<String, dynamic>;
        _currentProfile = decoded.cast<String, String>();
      } catch (e) {
        // If decoding fails, start with empty profile
        _currentProfile = {};
      }
    } else {
      _currentProfile = {};
    }
    
    _isLoaded = true;
  }

  /// Save profile to persistent storage
  Future<void> _saveProfile() async {
    _prefs ??= await SharedPreferences.getInstance();
    
    if (_currentProfile.isEmpty) {
      await _prefs!.remove(_profileKey);
    } else {
      final profileJson = json.encode(_currentProfile);
      await _prefs!.setString(_profileKey, profileJson);
    }
  }

  /// Ensure profile is loaded
  Future<void> _ensureLoaded() async {
    if (!_isLoaded) {
      await _loadProfile();
    }
  }

  /// Dispose resources
  void dispose() {
    _currentProfile.clear();
    _isLoaded = false;
  }
}
