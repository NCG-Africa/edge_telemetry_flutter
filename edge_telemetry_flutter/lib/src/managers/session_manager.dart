import 'package:shared_preferences/shared_preferences.dart';

/// Manages session lifecycle and provides session context for telemetry
class SessionManager {
  static const String _sessionCountKey = 'edge_telemetry_session_count';
  static const String _firstSessionKey = 'edge_telemetry_first_session';

  String? _currentSessionId;
  DateTime? _sessionStartTime;
  SharedPreferences? _prefs;

  // Session counters
  int _eventCount = 0;
  int _metricCount = 0;
  final Set<String> _visitedScreens = {};

  /// Start a new session
  Future<void> startSession(String sessionId) async {
    _currentSessionId = sessionId;
    _sessionStartTime = DateTime.now();

    // Reset counters
    _eventCount = 0;
    _metricCount = 0;
    _visitedScreens.clear();

    // Update session count in storage
    _prefs ??= await SharedPreferences.getInstance();
    final sessionCount = (_prefs!.getInt(_sessionCountKey) ?? 0) + 1;
    await _prefs!.setInt(_sessionCountKey, sessionCount);

    // Mark first session flag
    if (sessionCount == 1) {
      await _prefs!.setBool(_firstSessionKey, true);
    }
  }

  /// Get comprehensive session attributes
  Map<String, String> getSessionAttributes() {
    if (_currentSessionId == null || _sessionStartTime == null) {
      return {};
    }

    final now = DateTime.now();
    final duration = now.difference(_sessionStartTime!);

    return {
      'session.id': _currentSessionId!,
      'session.start_time': _sessionStartTime!.toIso8601String(),
      'session.duration_ms': duration.inMilliseconds.toString(),
      'session.event_count': _eventCount.toString(),
      'session.metric_count': _metricCount.toString(),
      'session.screen_count': _visitedScreens.length.toString(),
      'session.visited_screens': _visitedScreens.join(','),
      'session.is_first_session': _isFirstSession().toString(),
      'session.total_sessions': _getTotalSessions().toString(),
    };
  }

  /// Record an event (increment counter)
  void recordEvent() {
    _eventCount++;
  }

  /// Record a metric (increment counter)
  void recordMetric() {
    _metricCount++;
  }

  /// Record a visited screen
  void recordScreen(String screenName) {
    _visitedScreens.add(screenName);
  }

  /// Get current session ID
  String? get currentSessionId => _currentSessionId;

  /// Get session start time
  DateTime? get sessionStartTime => _sessionStartTime;

  /// Get session duration
  Duration? get sessionDuration {
    if (_sessionStartTime == null) return null;
    return DateTime.now().difference(_sessionStartTime!);
  }

  /// Check if this is the first session ever
  bool _isFirstSession() {
    if (_prefs == null) return false;
    return _prefs!.getBool(_firstSessionKey) ?? false;
  }

  /// Get total number of sessions
  int _getTotalSessions() {
    if (_prefs == null) return 0;
    return _prefs!.getInt(_sessionCountKey) ?? 0;
  }

  /// Get session statistics
  Map<String, dynamic> getSessionStats() {
    return {
      'sessionId': _currentSessionId,
      'startTime': _sessionStartTime?.toIso8601String(),
      'duration': sessionDuration?.inMilliseconds,
      'eventCount': _eventCount,
      'metricCount': _metricCount,
      'screenCount': _visitedScreens.length,
      'visitedScreens': _visitedScreens.toList(),
      'isFirstSession': _isFirstSession(),
      'totalSessions': _getTotalSessions(),
    };
  }

  /// End the current session
  void endSession() {
    // Clear first session flag after first session ends
    if (_isFirstSession()) {
      _prefs?.setBool(_firstSessionKey, false);
    }

    _currentSessionId = null;
    _sessionStartTime = null;
    _eventCount = 0;
    _metricCount = 0;
    _visitedScreens.clear();
  }
}
