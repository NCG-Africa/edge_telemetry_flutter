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

  /// Called immediately before `session.finalized` is built, so anything
  /// holding items back until the session ends can emit them into the session
  /// that produced them. The frame reservoir binds
  /// `FrameCaptureHook.flushReservoir` here — without it a rotation would carry
  /// the old session's two worst windows into the new session's ids.
  void Function()? onBeforeFinalize;

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

  /// Journeys declared open by `EdgeTelemetry.startTask`, keyed by name — a
  /// duplicate start supersedes, because mobile journeys are sequential and the
  /// second declaration is the live one.
  ///
  /// It lives **here** rather than in a manager of its own for one reason: every
  /// requirement a task holder has is something this class already does. Session
  /// scope is a task's lifetime (`_resetCounters` clears it on rotation for
  /// free), the abandonment terminal is this class's two finalize paths, and the
  /// persistence is the record this class already writes. A `TaskManager` would
  /// have needed two callbacks back into here to reach all three.
  final Map<String, _OpenTask> _openTasks = {};

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

  /// The "next event" idle check: rotate if idle exceeded (backdated to the last
  /// activity), else just bump `lastActivityAt`. No-op while rotating (the
  /// bookends re-enter here).
  ///
  /// Called by the Collector before every event, and by [startTask] — which
  /// emits nothing, but declaring a task is activity all the same. The facade
  /// asks a second time before it freezes trace context, because the freeze has
  /// to land on the far side of any rotation this triggers.
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
    _openTasks.clear();
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

  // ==================== DECLARED TASKS (#92) ====================

  /// Open a declared journey. [traceAttributes] is the caller's **already
  /// frozen** trace child (`TraceManager.startChild()?.attributes`), frozen at
  /// this instant and carried verbatim to the terminal minutes later.
  ///
  /// The attribute bag rather than the `FrozenTrace` itself, unlike
  /// `ScreenLoadHook`: that class lives downstream of this one, while
  /// `FrozenTrace` lives in `trace_manager.dart`, which imports *this* file.
  /// Taking the object would put a second edge on "exactly one dependency edge:
  /// TraceManager → SessionManager". Unwrapping at the call site is the price of
  /// keeping that edge one-directional.
  ///
  /// Frozen at start rather than read at the terminal because this is the
  /// strongest instance of the freeze rule in the SDK: a root is capped at 10
  /// seconds, so a minutes-long task reading ambient context at its terminal
  /// would reparent onto whatever unrelated tap happened to be open then.
  /// Empty when no root was live — **a task mints no root of its own.** A fifth
  /// root type with no sibling to conform to would give every request inside
  /// the task two candidate parents for minutes.
  ///
  /// Costs no wire item: the start is held, and only the terminal is emitted.
  ///
  /// [beforeEvent] runs first, for the same reason the Collector runs it before
  /// every event: declaring a task **is** activity. Without it, a task started
  /// after a 40-minute foreground idle would be held against the dying session
  /// and then abandoned — at a duration of nearly zero — by the rotation the
  /// very next event triggers.
  void startTask(String name,
      [Map<String, String> traceAttributes = const {}]) {
    beforeEvent();
    _openTasks[name] = _OpenTask(start: _clock(), trace: traceAttributes);
    _persist();
  }

  /// Close a declared journey with [outcome] (`completed` / `failed`).
  ///
  /// A name that was never started, or has already been closed, is a **no-op**
  /// — that is what fire-and-forget means here, and it is why an unclosed start
  /// has no failure mode: nothing is waiting on a matching call.
  void endTask(String name, TaskOutcome outcome) {
    final task = _openTasks.remove(name);
    if (task == null) return;
    _emit?.call(EdgeEvent.task(
      name: name,
      outcome: outcome,
      duration: _elapsed(task.start, _clock()),
      traceAttributes: task.trace,
    ));
    _persist();
  }

  /// One `task.complete` per still-open task, `outcome: abandoned`.
  ///
  /// **Session finalize is the only trigger.** Navigation-away and
  /// backgrounding are explicitly *not* triggers: the motivating example is a
  /// transfer spanning four routes, so navigation-away would abandon every task
  /// the feature exists to measure, and reading the OTP is step 2 of that happy
  /// path, so backgrounding would report the commonest mobile-banking flow as a
  /// failure.
  ///
  /// [end] is the session's **last activity**, already backdated by both
  /// callers — so an abandoned task measures start → last activity, not →
  /// finalize wall-clock. A session killed while backgrounded for two hours
  /// must not report a two-hour task.
  /// [tasks] is consumed as given, so callers on the live map hand over a copy:
  /// `_emit` re-enters the Collector, and a consumer callback that calls
  /// `startTask` from there would otherwise mutate the map mid-iteration.
  void _abandonOpenTasks(Map<String, _OpenTask> tasks, DateTime end,
      TaskAbandonSource source, String sessionId) {
    for (final entry in tasks.entries) {
      _emit?.call(EdgeEvent.task(
        name: entry.key,
        outcome: TaskOutcome.abandoned,
        duration: _elapsed(entry.value.start, end),
        sessionId: sessionId,
        abandonSource: source,
        traceAttributes: entry.value.trace,
      ));
    }
  }

  /// Clamped at zero: a recovered start comes off a record written by a previous
  /// process, and a user who moved their clock backwards must not ship a
  /// negative duration into a column that is averaged.
  static Duration _elapsed(DateTime start, DateTime end) =>
      end.isBefore(start) ? Duration.zero : end.difference(start);

  // ==================== FINALIZE / JOURNEY SUMMARY ====================

  void _emitFinalizeCurrent(DateTime end) {
    if (_currentSessionId == null || _sessionStartTime == null) return;
    // Before the journey summary is built, so a deferred item's own counters
    // are included in the numbers this bookend reports.
    onBeforeFinalize?.call();
    // Copied and cleared *before* emitting: the copy is what makes a re-entrant
    // `startTask` safe, and clearing here means this method no longer depends on
    // `_rotate` going on to call `_beginSession` → `_resetCounters` to keep a
    // task from being abandoned twice.
    final open = Map.of(_openTasks);
    _openTasks.clear();
    _abandonOpenTasks(
        open, end, TaskAbandonSource.sessionEnd, _currentSessionId!);
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
    // Before the bookend, and before `_beginSession` — so these rows carry the
    // dead session's own `session.id` from the record rather than the live
    // session's from the context snapshot, exactly as the bookend does.
    _abandonOpenTasks(_OpenTask.decodeAll(r['tasks']), end,
        TaskAbandonSource.launchRecovery, id);
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

  // ponytail: persist on start/pause/resume and on each task edge — never per
  // event. Tasks get their own two calls, against #92's "ride the existing
  // writes" line, because the lifecycle edges alone are wrong in both
  // directions on a *foreground crash*, which is the case the record exists
  // for: a task opened since the last edge would never be reported abandoned,
  // and one closed since the last edge would be reported abandoned a second
  // time on the next launch. Same key, same format, same method — two more
  // calls at human rate, not a second persistence layer.
  //
  // Ceiling: a kill with no preceding `paused` loses activity since the last edge. Accepted because iOS/Android
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
        if (_openTasks.isNotEmpty)
          'tasks': _openTasks.map((k, v) => MapEntry(k, v.toJson())),
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
  /// record intact so the next launch backdate-finalizes this session — open
  /// tasks included, which is why they are dropped here without emitting: they
  /// are reported on the next launch as `launch_recovery`, by the same rule and
  /// on the same row as the session itself.
  void endSession() {
    if (_isFirstSession()) _prefs?.setBool(_firstSessionKey, false);
    _currentSessionId = null;
    _sessionStartTime = null;
    _lastActivityAt = null;
    _resetCounters();
  }
}

/// One declared journey held open, and the shape it takes in the session record.
///
/// The frozen trace map is stored **verbatim** rather than as named fields: it
/// is already the exact bag the terminal event ships, so a round trip through
/// prefs neither reshapes it nor needs updating when a trace key is added. That
/// is what makes a kill-recovered abandonment arrive with its attribution
/// intact — the `trace.id` and `rum.action.id` it carries are the ones frozen in
/// the process that died.
class _OpenTask {
  _OpenTask({required this.start, required this.trace});

  final DateTime start;
  final Map<String, String> trace;

  Map<String, dynamic> toJson() => {
        'start': start.toIso8601String(),
        if (trace.isNotEmpty) 'trace': trace,
      };

  /// Decode the record's `tasks` block. Anything unparseable is skipped rather
  /// than thrown — the same rule the record itself follows, for the same reason:
  /// a corrupt record must not take init down with it.
  static Map<String, _OpenTask> decodeAll(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, _OpenTask>{};
    raw.forEach((key, value) {
      if (value is! Map) return;
      final start = DateTime.tryParse(value['start'] as String? ?? '');
      if (start == null) return;
      out['$key'] = _OpenTask(
        start: start,
        trace: (value['trace'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ??
            const {},
      );
    });
    return out;
  }
}
