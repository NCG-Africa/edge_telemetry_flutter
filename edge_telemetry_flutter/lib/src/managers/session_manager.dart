import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../capture/capture_hook.dart' show EventSink;
import '../core/edge_event.dart';

/// Timer-free lazy session model (spec #15 §2 / ticket #24).
///
/// A session rotates only on the **30-minute idle rule**, evaluated lazily on
/// the next event ([beforeEvent]) or on [handleResume] — never on a
/// `Timer.periodic` (a backgrounded Flutter app can't run timers). `paused`
/// flushes and marks (see [handlePause]); the finalize is deferred to
/// resume-after-idle, the next in-app rotation, or the next launch
/// ([recoverAndStart]) — always **backdated** to the last activity.
///
/// `session.id` + the running counters are persisted to `shared_preferences`
/// so a killed app still finalizes its last session on the following launch.
class SessionManager {
  // Legacy keys (kept for is-first/total-sessions attributes).
  static const String _sessionCountKey = 'edge_telemetry_session_count';
  static const String _firstSessionKey = 'edge_telemetry_first_session';

  // The kill-recovery record: the one not-yet-finalized session, as JSON.
  static const String _recordKey = 'edge_telemetry_session_record';

  /// Where `session.started` / `session.finalized` go (the Collector). Null in
  /// state-only tests → bookends are simply not emitted.
  void Function(EdgeEvent event)? _emit;

  /// New session id minter (the facade injects the family-format generator).
  final String Function() _newId;

  /// Injectable clock — tests advance it to exercise idle rotation.
  final DateTime Function() _clock;

  /// Idle window after which the next activity rotates the session.
  final Duration idleTimeout;

  /// Per-session sampling roll (spec #15 Phase 3 / ticket #25). Called once at
  /// [_beginSession]; true = keep this session's subject-to-sample events.
  /// Null = keep-all (default, `sampleRate` 1.0) → no `session.sampled` emitted,
  /// byte-identical with the pre-sampling wire.
  final bool Function()? _sampledRoll;

  SharedPreferences? _prefs;

  String? _currentSessionId;
  DateTime? _sessionStartTime;
  DateTime? _lastActivityAt;
  bool _rotating = false;

  /// This session's roll outcome as a wire string, or null when keep-all.
  String? _sampled;

  // Journey counters.
  int _eventCount = 0;
  int _metricCount = 0;
  int _errorCount = 0;
  int _crashCount = 0;
  int _httpRequestCount = 0;
  final Set<String> _visitedScreens = {};
  final List<String> _screenJourney = [];

  SessionManager({
    void Function(EdgeEvent event)? emit,
    String Function()? newSessionId,
    DateTime Function()? clock,
    bool Function()? sampledRoll,
    this.idleTimeout = const Duration(minutes: 30),
    SharedPreferences? prefs,
  })  : _emit = emit,
        _newId = newSessionId ??
            (() => 'session_${DateTime.now().millisecondsSinceEpoch}'),
        _clock = clock ?? DateTime.now,
        _sampledRoll = sampledRoll,
        _prefs = prefs;

  /// Late-bind the sink once the Collector exists (breaks the session↔collector
  /// construction cycle). Called by `TelemetryWiring.build`.
  void bindSink(EventSink sink) => _emit = sink.add;

  // ==================== LIFECYCLE ====================

  /// Init-time entry: finalize any persisted (killed) prior session backdated to
  /// its last activity, then start a fresh one. Emits at most one
  /// `session.finalized` + one `session.started`.
  Future<void> recoverAndStart() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_recordKey);
    if (raw != null) {
      _emitFinalizeFromRecord(raw);
    }
    _beginSession(_newId());
  }

  /// Legacy/explicit start with a caller-supplied id (used by existing seam
  /// tests). Resets counters and — if a sink is bound — emits `session.started`.
  Future<void> startSession(String sessionId) async {
    _prefs ??= await SharedPreferences.getInstance();
    _beginSession(sessionId);
  }

  /// Synchronous session begin. Prefs writes are fire-and-forget so the
  /// `session.started` emit — and a rotation's finalize→start pair — complete
  /// synchronously (no `await` splitting the bookends across microtasks).
  void _beginSession(String sessionId) {
    _currentSessionId = sessionId;
    final now = _clock();
    _sessionStartTime = now;
    _lastActivityAt = now;
    // Roll sampling once per session; the whole session drops-or-keeps coherently.
    _sampled = _sampledRoll == null ? null : _sampledRoll!().toString();
    _resetCounters();

    if (_prefs != null) {
      final sessionCount = (_prefs!.getInt(_sessionCountKey) ?? 0) + 1;
      _prefs!.setInt(_sessionCountKey, sessionCount);
      if (sessionCount == 1) _prefs!.setBool(_firstSessionKey, true);
    }

    _persist();
    _emit?.call(EdgeEvent.session('session.started', {
      'session.id': sessionId,
      'session.start_time': now.toIso8601String(),
    }));
  }

  /// The "next event" idle check. Called by the Collector before every event:
  /// rotate if idle exceeded (backdated to the last activity), else just bump
  /// `lastActivityAt`. No-op while rotating (the bookends re-enter here).
  void beforeEvent() {
    if (_rotating || _currentSessionId == null || _lastActivityAt == null) {
      return;
    }
    final now = _clock();
    if (now.difference(_lastActivityAt!) > idleTimeout) {
      _rotate(_lastActivityAt!);
    } else {
      _lastActivityAt = now;
    }
  }

  /// `AppLifecycleState.paused`: mark the background time and persist. The
  /// caller flushes the Pipeline first (nothing lost to a subsequent kill).
  /// **Never finalizes** — a brief app-switch must not rotate the session.
  void handlePause() {
    if (_currentSessionId == null) return;
    _lastActivityAt = _clock();
    _persist();
  }

  /// `AppLifecycleState.resumed`: rotate if we were idle past the window
  /// (backdated to the background time), else continue the same session.
  void handleResume() {
    if (_currentSessionId == null || _lastActivityAt == null) return;
    final now = _clock();
    if (now.difference(_lastActivityAt!) > idleTimeout) {
      _rotate(_lastActivityAt!);
    } else {
      _lastActivityAt = now;
      _persist();
    }
  }

  void _rotate(DateTime backdatedEnd) {
    if (_rotating) return;
    _rotating = true;
    _emitFinalizeCurrent(backdatedEnd);
    _beginSession(_newId());
    _rotating = false;
  }

  // ==================== COUNTERS ====================

  void recordEvent() => _eventCount++;
  void recordMetric() => _metricCount++;
  void recordError() => _errorCount++;
  void recordCrash() => _crashCount++;
  void recordHttpRequest() => _httpRequestCount++;

  void _resetCounters() {
    _eventCount = 0;
    _metricCount = 0;
    _errorCount = 0;
    _crashCount = 0;
    _httpRequestCount = 0;
    _visitedScreens.clear();
    _screenJourney.clear();
  }

  /// Ordered route path (for `screen_journey`) + distinct set (for count).
  void recordScreen(String screenName) {
    _visitedScreens.add(screenName);
    _screenJourney.add(screenName);
  }

  // ==================== FINALIZE / JOURNEY SUMMARY ====================

  void _emitFinalizeCurrent(DateTime end) {
    if (_currentSessionId == null || _sessionStartTime == null) return;
    _emit?.call(EdgeEvent.session(
        'session.finalized',
        _journeyAttributes(
          id: _currentSessionId!,
          start: _sessionStartTime!,
          end: end,
          eventCount: _eventCount,
          errorCount: _errorCount,
          crashCount: _crashCount,
          httpCount: _httpRequestCount,
          screenCount: _visitedScreens.length,
          journey: _screenJourney,
        )));
  }

  void _emitFinalizeFromRecord(String raw) {
    final Map<String, dynamic> r;
    try {
      r = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return; // corrupt record → skip recovery rather than crash init
    }
    final start = DateTime.tryParse(r['start'] as String? ?? '');
    final end = DateTime.tryParse(r['lastActivity'] as String? ?? '');
    final id = r['id'] as String?;
    if (id == null || start == null || end == null) return;
    _emit?.call(EdgeEvent.session(
        'session.finalized',
        _journeyAttributes(
          id: id,
          start: start,
          end: end,
          eventCount: (r['eventCount'] as num?)?.toInt() ?? 0,
          errorCount: (r['errorCount'] as num?)?.toInt() ?? 0,
          crashCount: (r['crashCount'] as num?)?.toInt() ?? 0,
          httpCount: (r['httpCount'] as num?)?.toInt() ?? 0,
          screenCount: (r['screenCount'] as num?)?.toInt() ?? 0,
          journey: (r['journey'] as List?)?.cast<String>() ?? const [],
          recovered: true,
        )));
  }

  Map<String, String> _journeyAttributes({
    required String id,
    required DateTime start,
    required DateTime end,
    required int eventCount,
    required int errorCount,
    required int crashCount,
    required int httpCount,
    required int screenCount,
    required List<String> journey,
    bool recovered = false,
  }) {
    // Last 20 hops only, so a multi-hour session can't emit a giant attribute.
    final capped =
        journey.length > 20 ? journey.sublist(journey.length - 20) : journey;
    return {
      'session.id': id,
      'session.start_time': start.toIso8601String(),
      'session.end_time': end.toIso8601String(),
      'session.duration_ms': end.difference(start).inMilliseconds.toString(),
      'session.event_count': eventCount.toString(),
      'session.error_count': errorCount.toString(),
      'session.crash_count': crashCount.toString(),
      'session.screen_count': screenCount.toString(),
      'session.http_request_count': httpCount.toString(),
      'session.screen_journey': capped.join('>'),
      if (recovered) 'session.recovered': 'true',
    };
  }

  // ponytail: persist on start/pause/resume only, not per-event — one prefs
  // write per lifecycle edge, not per event. Ceiling: a kill with no preceding
  // `paused` loses activity since the last edge. Accepted because iOS/Android
  // both deliver `paused` before a kill (spec §2.2); persist per-event if that
  // assumption ever fails.
  void _persist() {
    if (_prefs == null || _currentSessionId == null) return;
    _prefs!.setString(
      _recordKey,
      jsonEncode({
        'id': _currentSessionId,
        'start': _sessionStartTime!.toIso8601String(),
        'lastActivity': _lastActivityAt!.toIso8601String(),
        'eventCount': _eventCount,
        'errorCount': _errorCount,
        'crashCount': _crashCount,
        'httpCount': _httpRequestCount,
        'screenCount': _visitedScreens.length,
        'journey': _screenJourney,
      }),
    );
  }

  // ==================== CONTEXT ATTRIBUTES ====================

  /// Live session attributes merged into every event by `ContextManager`.
  Map<String, String> getSessionAttributes() {
    if (_currentSessionId == null || _sessionStartTime == null) return {};
    final duration = _clock().difference(_sessionStartTime!);
    return {
      'session.id': _currentSessionId!,
      'session.start_time': _sessionStartTime!.toIso8601String(),
      'session.duration_ms': duration.inMilliseconds.toString(),
      'session.event_count': _eventCount.toString(),
      'session.metric_count': _metricCount.toString(),
      'session.error_count': _errorCount.toString(),
      'session.crash_count': _crashCount.toString(),
      'session.http_request_count': _httpRequestCount.toString(),
      'session.screen_count': _visitedScreens.length.toString(),
      'session.visited_screens': _visitedScreens.join(','),
      'session.is_first_session': _isFirstSession().toString(),
      'session.total_sessions': _getTotalSessions().toString(),
      if (_sampled != null) 'session.sampled': _sampled!,
    };
  }

  String? get currentSessionId => _currentSessionId;
  DateTime? get sessionStartTime => _sessionStartTime;
  Duration? get sessionDuration => _sessionStartTime == null
      ? null
      : _clock().difference(_sessionStartTime!);

  bool _isFirstSession() => _prefs?.getBool(_firstSessionKey) ?? false;
  int _getTotalSessions() => _prefs?.getInt(_sessionCountKey) ?? 0;

  Map<String, dynamic> getSessionStats() => {
        'sessionId': _currentSessionId,
        'startTime': _sessionStartTime?.toIso8601String(),
        'duration': sessionDuration?.inMilliseconds,
        'eventCount': _eventCount,
        'metricCount': _metricCount,
        'errorCount': _errorCount,
        'crashCount': _crashCount,
        'httpRequestCount': _httpRequestCount,
        'screenCount': _visitedScreens.length,
        'visitedScreens': _visitedScreens.toList(),
        'screenJourney': List<String>.from(_screenJourney),
        'isFirstSession': _isFirstSession(),
        'totalSessions': _getTotalSessions(),
      };

  /// Clear in-memory state (call on dispose). Deliberately leaves the persisted
  /// record intact so the next launch backdate-finalizes this session.
  void endSession() {
    if (_isFirstSession()) _prefs?.setBool(_firstSessionKey, false);
    _currentSessionId = null;
    _sessionStartTime = null;
    _lastActivityAt = null;
    _resetCounters();
  }
}
