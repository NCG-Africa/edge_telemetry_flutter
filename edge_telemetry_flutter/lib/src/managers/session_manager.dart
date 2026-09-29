import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../capture/capture_hook.dart' show EventSink;
import '../core/edge_event.dart';
import 'identity_format.dart';

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

  /// Called at the start of every session, rotations included. The budget
  /// governor binds `CaptureGate.resetBudget` here — the item allowance is per
  /// session, so a rotation starts a fresh one.
  void Function()? onSessionStart;

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

  /// Trace roots minted this session — see [recordAction].
  int _actionCount = 0;
  final Set<String> _visitedScreens = {};
  final List<String> _screenJourney = [];

  /// The current screen *visit*, not the route — see [recordScreen].
  String? _currentScreenId;

  /// When the current visit began. The final screen's dwell is otherwise lost
  /// on every session — the last screen is never navigated away from, so the
  /// navigation event that carries dwell never fires for it. It lands on the
  /// finalize bookend instead, at **zero extra items**.
  DateTime? _currentScreenStart;

  /// Whether that visit ever painted. Same rule as the observer's dwell: a
  /// screen nobody saw reports no time, because the frame still on the glass
  /// belongs to the screen before it. Set by the screen-load hook's first
  /// post-frame callback.
  bool _currentScreenVisible = false;

  /// Items the SDK built but never sent, by reason. One counter, several
  /// clients: the off-canon allowlist gate today (#79), tier shedding / the
  /// action cap / the error caps later. Ships on `session.finalized` so a drop
  /// is found by telemetry, not by audit.
  final Map<String, int> _droppedByReason = {};

  /// Attribute values replaced by the cardinality sentinel this session. Its
  /// own counter, not a `dropped` reason: a capped *value* is not a dropped
  /// *item*, and folding it into `session.dropped_item_count` would corrupt
  /// the one number the budget is asserted against.
  int _cardinalityCapped = 0;

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
    onSessionStart?.call();

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

  /// Count one trace root minted (`TraceManager.mint`), which is what
  /// `session.action_count` means. Counting roots rather than emitted
  /// `ui.interaction` events is what keeps the per-session emission cap
  /// honest: 400 actions against 100 recorded events reads as truth, where a
  /// count of emissions would read as a quiet session.
  void recordAction() => _actionCount++;

  /// Count one item the SDK declined to send. [reason] is a short stable slug
  /// (`off_canon`, …) — it rides the finalize bookend verbatim.
  void recordDropped(String reason) =>
      _droppedByReason[reason] = (_droppedByReason[reason] ?? 0) + 1;

  /// Count one attribute value replaced by `kCardinalitySentinel`.
  void recordCardinalityCap() => _cardinalityCapped++;

  void _resetCounters() {
    _eventCount = 0;
    _metricCount = 0;
    _errorCount = 0;
    _crashCount = 0;
    _httpRequestCount = 0;
    _actionCount = 0;
    _visitedScreens.clear();
    _screenJourney.clear();
    _currentScreenId = null;
    _currentScreenStart = null;
    _currentScreenVisible = false;
    _droppedByReason.clear();
    _cardinalityCapped = 0;
  }

  /// Ordered route path (for `screen_journey`) + distinct set (for count), and
  /// the mint site for `screen.id`.
  ///
  /// A fresh id on **every entry**, so a back-navigation to an already-visited
  /// route is a new visit with a new id. Chosen over reconstructing visits from
  /// the navigation sequence because offline batches arrive hours late and out
  /// of order, which makes arrival order silently wrong.
  ///
  /// 16-hex and deliberately not family-prefixed: the id is scoped by
  /// `session.id`, which already rides every item, so it needs no device-global
  /// uniqueness — 16 bytes rather than ~45 on a key that appears everywhere.
  /// It lives here and not on `TraceManager` because session scope *is* its
  /// lifetime: `_resetCounters` already clears it on rotation, for free. After
  /// this there is no code path from a screen entry to the trace manager.
  ///
  /// A screen visit is **deliberately not a span**, tempting as its start/end
  /// shape is: an `http.request` inside a tap inside a screen would then have
  /// two candidate parents, and either the screen becomes the root —
  /// contradicting `rum.action.id` as the sole join key — or the span tree
  /// grows a level the backend's view does not model. `screen.id` is an
  /// ordinary correlating attribute, outside the tree.
  void recordScreen(String screenName) {
    _visitedScreens.add(screenName);
    _screenJourney.add(screenName);
    _currentScreenId = secureHex16();
    _currentScreenStart = _clock();
    _currentScreenVisible = false;
  }

  /// The current screen visit reached its first frame.
  void markCurrentScreenVisible() => _currentScreenVisible = true;

  /// The current screen visit's id, or null before the first navigation.
  String? get currentScreenId => _currentScreenId;

  /// The route name of the current screen visit, or null before the first
  /// navigation. Read by the pointer hook for `ui.screen` — the *name*, not
  /// the visit id, which already rides every item as `screen.id`.
  String? get currentScreenName =>
      _screenJourney.isEmpty ? null : _screenJourney.last;

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
          dropped: _droppedByReason,
          cardinalityCapped: _cardinalityCapped,
          lastScreenStart: _currentScreenVisible ? _currentScreenStart : null,
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
          dropped: (r['dropped'] as Map?)
                  ?.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0)) ??
              const {},
          cardinalityCapped: (r['capped'] as num?)?.toInt() ?? 0,
          lastScreenStart: r['screenVisible'] == true
              ? DateTime.tryParse(r['screenStart'] as String? ?? '')
              : null,
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
    required Map<String, int> dropped,
    required int cardinalityCapped,
    DateTime? lastScreenStart,
    bool recovered = false,
  }) {
    // Last 20 hops only, so a multi-hour session can't emit a giant attribute.
    final lastHops =
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
      'session.screen_journey': lastHops.join('>'),
      'session.dropped_item_count':
          dropped.values.fold(0, (a, b) => a + b).toString(),
      if (dropped.isNotEmpty)
        'session.dropped_reasons': (dropped.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)))
            .map((e) => '${e.key}=${e.value}')
            .join(','),
      if (cardinalityCapped > 0)
        'session.cardinality_capped_count': cardinalityCapped.toString(),
      // The final screen's dwell. One key on an item that was being sent
      // anyway, rather than a `screen.duration` nobody is there to emit.
      if (lastScreenStart != null && !end.isBefore(lastScreenStart))
        'session.last_screen_duration_ms':
            end.difference(lastScreenStart).inMilliseconds.toString(),
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
        if (_currentScreenStart != null)
          'screenStart': _currentScreenStart!.toIso8601String(),
        'screenVisible': _currentScreenVisible,
        'dropped': _droppedByReason,
        'capped': _cardinalityCapped,
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
      'session.action_count': _actionCount.toString(),
      'session.screen_count': _visitedScreens.length.toString(),
      'session.visited_screens': _visitedScreens.join(','),
      // Per-item, not batch-scoped: it changes within a batch, so the hoist
      // must never lift it (`isHoistedContextKey` leaves it alone by design).
      if (_currentScreenId != null) 'screen.id': _currentScreenId!,
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
        'actionCount': _actionCount,
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
