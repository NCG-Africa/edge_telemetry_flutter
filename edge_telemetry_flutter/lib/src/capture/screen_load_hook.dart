// lib/src/capture/screen_load_hook.dart
//
// Per-screen load timing (#88, spec §7). One `screen.load` per screen entry,
// at the first terminal it reaches.
//
// **Two marks, not three.** Render-complete and time-to-interactive are
// rejected here with reasons rather than deferred:
//
// - *Render-complete* is a progressive-paint idea. Flutter composites one
//   frame from one widget tree; there is no second, later paint for the
//   metric to name. Anything that arrives after the first raster is new data,
//   which is what `settled` already measures.
// - *Time to interactive* is a web metric about a main thread being quiet
//   enough to service input. A Flutter route's gesture arena is live on frame
//   one — taps are routed while the first frame is still rasterising — so the
//   number would be a constant equal to first frame, dressed up as a second
//   measurement.
//
// **Settled is inferred by default**, which inverts the industry manual-first
// default deliberately. The sibling rejected a manual API on its own recorded
// evidence: the data is silently missing wherever consumers do not call it,
// and measurement showed they do not. The inference costs no new machinery —
// the screen id is ambient, the request claims it at call entry, and the
// global override seam sees every request app-wide. That is a join the sibling
// cannot make, because its HTTP interception is opt-in.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/capture_gate.dart';
import '../core/config/collection_tier.dart';
import '../core/edge_event.dart';
import '../core/screen_inflight.dart';
import '../managers/session_manager.dart';
import '../managers/trace_manager.dart';
import 'capture_hook.dart';

/// `screen.load.outcome` — four values, and every screen entry reaches exactly
/// one of them.
const String kScreenLoadSettled = 'settled';
const String kScreenLoadAbandoned = 'abandoned';
const String kScreenLoadDeadlineExceeded = 'deadline_exceeded';
const String kScreenLoadBackgrounded = 'backgrounded';

/// `screen.load.source` — on **every** event, so an inferred number can never
/// be read as a measured one. There is no third value: absence of the key
/// would be the ambiguity the key exists to remove.
const String kScreenLoadInferred = 'inferred';
const String kScreenLoadReported = 'reported';

/// Quiet window after the last in-flight request before a screen counts as
/// settled.
const Duration kScreenQuietWindow = Duration(milliseconds: 500);

/// Emits one `screen.load` per screen entry.
///
/// Driven by [NavCaptureHook] (entry), the lifecycle hook (backgrounding), the
/// HTTP seams (in-flight counts) and the facade (`reportScreenSettled`). It
/// holds no observer of its own: the route push is already observed once.
class ScreenLoadHook implements CaptureHook {
  /// **Pinned to the action-root cap, not chosen.** A load still running past
  /// `TraceManager.rootCap` emits after its own `rum.action.id` has aged out,
  /// so the row would arrive unjoinable to the action that caused it. Picking
  /// any other number would mean picking, independently, how long an
  /// unattributable row is worth waiting for — a question already answered
  /// once, over there.
  static Duration get deadline => TraceManager.rootCap;

  final SessionManager session;

  /// Tier gate. Checked at [enter], **before** any attribute map or timer
  /// exists — gating at the Collector would pay for the whole load.
  final CaptureGate? gate;

  /// Mints the frozen child span the terminal event carries. Null in
  /// state-only tests, in which case the event is simply untraced.
  final TraceManager? trace;

  /// Injectable clock — tests advance it rather than waiting a real 500 ms.
  final DateTime Function() _clock;

  EventSink? _sink;
  _ScreenLoad? _open;

  ScreenLoadHook({
    required this.session,
    this.gate,
    this.trace,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  @override
  DisposeHandle start(EventSink sink) {
    _sink = sink;
    bindScreenInflightListener(_onInflightChanged);
    return () {
      bindScreenInflightListener(null);
      setCurrentScreen(null);
      _open?.cancelTimers();
      _open = null;
      _sink = null;
    };
  }

  /// A screen entry, called from the navigation hook **after**
  /// `SessionManager.recordScreen` has minted this visit's `screen.id`.
  ///
  /// It terminates any load still open as [kScreenLoadAbandoned] first: the
  /// user left, which is a terminal, and one event per entry means the
  /// previous entry's event is owed now rather than never.
  void enter(String screenName, {Map<String, String> routeContext = const {}}) {
    _terminate(kScreenLoadAbandoned);

    if (gate != null && !gate!.allows(Capture.screenLoad)) {
      setCurrentScreen(null);
      return;
    }
    final screenId = session.currentScreenId;
    if (screenId == null || _sink == null) return;

    setCurrentScreen(screenId);
    final load = _ScreenLoad(
      screenId: screenId,
      screenName: screenName,
      routeContext: routeContext,
      start: _clock(),
      frozen: trace?.startChild(),
    );
    _open = load;

    // **First frame is the first post-frame callback after the route push**,
    // with the navigation transition deliberately excluded — the callback runs
    // when the new route's first frame has been built and submitted, not when
    // the 300 ms slide finishes, and a transition duration the consumer chose
    // is not a fact about how slow their screen is.
    //
    // Raster-finish timing is rejected, not deferred: `addTimingsCallback`
    // reports whole frames with no route identity on them, so attributing one
    // to this screen means guessing by ordinal — and it fires for every frame
    // of the transition, which is the very thing being excluded above. The
    // rasterisation tail it would add is the compositor's, and jank already
    // has `frame.summary` and `long_task` to itself.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_open, load)) return;
      load.firstFrame = _clock();
      _armQuietWindow(load);
    });
    // `addPostFrameCallback` does not schedule a frame — it only books a seat
    // on the next one. A route push always dirties the tree, so in an app the
    // seat is filled either way; asking explicitly is what makes the mark
    // independent of that assumption rather than reliant on it.
    WidgetsBinding.instance.scheduleFrame();

    load.deadlineTimer =
        Timer(deadline, () => _terminate(kScreenLoadDeadlineExceeded));
  }

  /// The explicit override: the consumer declares this screen settled *now*.
  ///
  /// It wins over the inference wherever both could fire — that is the whole
  /// point of having it — and stamps `screen.load.source: reported`, so a
  /// dashboard mixing the two never reads a guess as a measurement.
  void reportSettled() => _terminate(kScreenLoadSettled, reported: true);

  /// `AppLifecycleState.paused`. A backgrounded app stops painting and its
  /// timers stop being trustworthy, so the load has no honest way to continue;
  /// it terminates as [kScreenLoadBackgrounded] rather than settling on a
  /// quiet window that is only quiet because the app is asleep.
  void onPaused() => _terminate(kScreenLoadBackgrounded);

  /// From the HTTP seams, via the in-flight registry.
  void _onInflightChanged(String screenId, int inFlight) {
    final load = _open;
    if (load == null || load.screenId != screenId) return;
    if (inFlight > 0) {
      // The screen started talking again — whatever quiet we had measured was
      // not the end of loading.
      load.quietTimer?.cancel();
      load.quietTimer = null;
      return;
    }
    _armQuietWindow(load);
  }

  /// Settled needs all three: the first frame is on screen, nothing this
  /// screen started is still in flight, and the quiet has held for
  /// [kScreenQuietWindow].
  void _armQuietWindow(_ScreenLoad load) {
    if (load.firstFrame == null) return;
    if (inFlightForScreen(load.screenId) > 0) return;
    load.quietTimer?.cancel();
    load.quietTimer =
        Timer(kScreenQuietWindow, () => _terminate(kScreenLoadSettled));
  }

  /// The one emit site. Every path in — settled, abandoned, deadline,
  /// backgrounded — lands here, which is what makes "one event per screen
  /// entry, at the first terminal" true by construction rather than by
  /// discipline: the open load is cleared before the event is built, so a
  /// second terminal for the same entry finds nothing to emit.
  void _terminate(String outcome, {bool reported = false}) {
    final load = _open;
    if (load == null) return;
    _open = null;
    load.cancelTimers();
    forgetScreen(load.screenId);

    final sink = _sink;
    if (sink == null) return;

    final settledMs = outcome == kScreenLoadSettled
        ? _clock().difference(load.start).inMilliseconds
        : null;

    sink.add(EdgeEvent.event(
      'screen.load',
      attributes: {
        'screen.name': load.screenName,
        // Its own, not the ambient one: by the time an `abandoned` terminal
        // fires, `screen.id` in the context snapshot is already the screen the
        // user moved *to*.
        'screen.id': load.screenId,
        'screen.load.outcome': outcome,
        'screen.load.source':
            reported ? kScreenLoadReported : kScreenLoadInferred,
        if (load.firstFrame != null)
          'screen.load.first_frame_ms':
              load.firstFrame!.difference(load.start).inMilliseconds.toString(),
        // **Non-settled paths carry no duration of their own.** An abandoned
        // or deadline-exceeded screen has a wall-clock number available, and
        // emitting it would put "how long until the user gave up" in the same
        // column as "how long the screen took" — the two are not comparable
        // and no consumer would be told which they were reading.
        if (settledMs != null) 'screen.load.settled_ms': settledMs.toString(),
        // No slow/fast verdict on the wire: banding is a query-time comparison
        // against the Apdex threshold, which is the backend's to move without
        // a client release.
        ...load.routeContext,
        ...?load.frozen?.attributes,
      },
      // The event is emitted seconds after the entry it describes, so the
      // ambient trace keys must be stripped before its own frozen copy merges
      // — including when the freeze found no open root at all.
      ownsTraceContext: true,
    ));
  }
}

/// One screen entry being timed.
class _ScreenLoad {
  _ScreenLoad({
    required this.screenId,
    required this.screenName,
    required this.routeContext,
    required this.start,
    required this.frozen,
  });

  final String screenId;
  final String screenName;
  final Map<String, String> routeContext;
  final DateTime start;
  final FrozenTrace? frozen;

  DateTime? firstFrame;
  Timer? quietTimer;
  Timer? deadlineTimer;

  void cancelTimers() {
    quietTimer?.cancel();
    deadlineTimer?.cancel();
    quietTimer = null;
    deadlineTimer = null;
  }
}
