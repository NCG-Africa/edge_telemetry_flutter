// lib/src/capture/frame_capture_hook.dart
//
// Windowed frame aggregation (#89, spec §9). Replaces v2's two allocated
// events per frame at 60–120 Hz with ~11 non-allocating scalar operations and
// at most two items per session.
//
// **The payload is the sibling's, verbatim** — ten keys, zero Flutter
// inventions, zero new columns. The build/raster triage split that looked like
// the thing only Flutter had is already inside that aggregate as two
// max-duration keys, so conforming *is* how the split survives aggregation.
//
// Three things about it are easy to "fix" wrongly:
//
// - **The thresholds are fixed absolutes and must not adapt to refresh rate.**
//   The rate is *recorded, not applied*. A refresh-adaptive threshold would
//   make `frame.slow_frames` mean "over this device's budget" while the
//   sibling's identical column means "over 16 ms" — the same column carrying
//   two quantities, which is the disease the whole canon exists to avoid.
// - **Total duration is `FrameTiming.totalSpan`, never build + raster.** Build
//   runs on the UI thread and raster on the raster thread, *pipelined*: their
//   sum is not a wall-clock span and it omits vsync overhead. v2 summed them
//   and over-reported drops.
// - **The aggregate carries no trace keys at all.** See [_emit].

import 'dart:ui' show FramePhase, FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/capture_gate.dart';
import '../core/config/collection_tier.dart';
import '../core/edge_event.dart';
import '../managers/session_manager.dart';
import 'capture_hook.dart';

/// A frame slower than one frame budget. Absolute, never refresh-derived.
const double kSlowFrameMs = 16;

/// A frozen frame — the same threshold `long_task` now fires on, so the SDK
/// stops holding two different opinions about what a bad frame is.
const double kFrozenFrameMs = 700;

/// The window's upper bound. A window normally ends at a screen change; this
/// caps the one that does not.
const Duration kFrameWindowCap = Duration(seconds: 10);

/// Windows held by the reservoir, which is also the `standard` tier's whole
/// item allowance for frames.
const int kFrameReservoirSize = 2;

/// Per-session `long_task` backstop. At `> 700 ms` a typical session produces
/// none; the cap exists for the runaway, not as a budget line.
const int kLongTaskCap = 100;

/// Accumulates frame timings per screen segment and emits `frame.summary`.
///
/// Both window-boundary checks run inside the existing timings callback —
/// frames arrive every ~8–16 ms, so no `Timer` is needed, which matters twice
/// on this package: a backgrounded Flutter app cannot run one reliably.
class FrameCaptureHook implements CaptureHook {
  /// Read once per window for `screen.name` / `screen.id`, and once per frame
  /// for the boundary check. Both are plain field reads.
  final SessionManager session;

  /// Splits the emitter; it never doubles it. Null = reservoir only, which is
  /// the `standard` behaviour and the right default for a state-only test.
  final CaptureGate? gate;

  /// Whether to run the windowing at all.
  ///
  /// False when the consumer wants `Capture.longTask` with `Capture.frames`
  /// off — `long_task` is a **per-frame predicate, independent of both** the
  /// aggregate and its `diagnostic` sibling, so the timings callback still has
  /// to run, and nothing accumulates behind it.
  final bool aggregate;

  /// Injectable clock, for the one wall-clock reading each window needs: its
  /// start, which the item is backdated to.
  final DateTime Function() _clock;

  /// Injectable display rate: `PlatformDispatcher` has no view in a unit test.
  final double? Function() _refreshRate;

  EventSink? _sink;
  TimingsCallback? _callback;

  _FrameWindow? _open;

  /// Keep-worst-[kFrameReservoirSize], ranked on absolute counts (see [_rank]).
  final List<_FrameWindow> _held = [];

  int _longTasks = 0;

  FrameCaptureHook({
    required this.session,
    this.gate,
    this.aggregate = true,
    DateTime Function()? clock,
    double? Function()? refreshRate,
  }) : _clock = clock ?? DateTime.now,
       _refreshRate = refreshRate ?? _platformRefreshRate;

  @override
  DisposeHandle start(EventSink sink) {
    _sink = sink;
    _callback = (timings) {
      for (final timing in timings) {
        recordFrame(timing);
      }
    };
    WidgetsBinding.instance.addTimingsCallback(_callback!);
    return () {
      if (_callback != null) {
        WidgetsBinding.instance.removeTimingsCallback(_callback!);
        _callback = null;
      }
      _open = null;
      _held.clear();
      _sink = null;
    };
  }

  /// The whole per-frame cost: three divisions, four comparisons, three max
  /// updates, one increment and one screen read. **No allocation** — the
  /// elapsed check reads the engine's own monotonic frame timestamp rather
  /// than minting a `DateTime`, which is also the more correct clock for a
  /// duration: a wall clock can be stepped by the OS mid-window.
  @visibleForTesting
  void recordFrame(FrameTiming timing) {
    final totalMs = timing.totalSpan.inMicroseconds / 1000;
    final buildMs = timing.buildDuration.inMicroseconds / 1000;
    final rasterMs = timing.rasterDuration.inMicroseconds / 1000;

    final frozen = totalMs > kFrozenFrameMs;
    // Ahead of the window, and outside `aggregate`: this predicate is nobody's
    // window product.
    if (frozen) _emitLongTask(totalMs, buildMs, rasterMs);
    if (!aggregate) return;

    final atMicros = timing.timestampInMicroseconds(FramePhase.rasterFinish);
    final window =
        _open ??= _FrameWindow(
          start: _clock(),
          startMicros: atMicros,
          screenId: session.currentScreenId,
          screenName: session.currentScreenName,
          refreshRate: _refreshRate(),
        );

    window.totalFrames++;
    if (totalMs > kSlowFrameMs) {
      window.slowFrames++;
      if (frozen) window.frozenFrames++;
    }
    if (totalMs > window.maxTotalMs) window.maxTotalMs = totalMs;
    if (buildMs > window.maxBuildMs) window.maxBuildMs = buildMs;
    if (rasterMs > window.maxRasterMs) window.maxRasterMs = rasterMs;
    window.endMicros = atMicros;

    // The boundary, checked after the accumulators — the sibling's ordering,
    // and the honest one: the timings callback lags the route push by a
    // frame, so the first frame reported after a screen change is the
    // outgoing screen's last frame, not the incoming screen's first.
    if (session.currentScreenId != window.screenId ||
        atMicros - window.startMicros >= kFrameWindowCap.inMicroseconds) {
      _close(window);
    }
  }

  /// `AppLifecycleState.paused` and `session.finalized`: close whatever is
  /// open, rank it, and send the survivors.
  ///
  /// An open window is ranked *first* so a session whose worst jank is
  /// happening right now can still evict a held one.
  void flushReservoir() {
    final open = _open;
    if (open != null) _close(open);
    for (final window in _held) {
      // **The reservoir is not drained, only read.** A survivor already sent
      // stays as a ranking incumbent for the rest of the session, so a
      // backgrounded-and-resumed session neither re-sends it nor starts
      // ranking from empty — which would reproduce, one pause at a time,
      // exactly the start-of-session bias the reservoir exists to avoid. A
      // later window only costs an item by being worse than what it evicts.
      if (window.emitted) continue;
      window.emitted = true;
      _emit(window);
    }
  }

  /// Per-session state starts fresh on rotation, like the governor's budget
  /// and the Collector's action cap. The reservoir is session-scoped too: its
  /// survivors are already gone by now, flushed by `onBeforeFinalize`, and a
  /// held window would otherwise be ranked against the next session's.
  void resetForNewSession() {
    _longTasks = 0;
    _held.clear();
  }

  void _close(_FrameWindow window) {
    _open = null;
    // The sibling's eligibility floor. Under the reservoir it is no longer
    // what makes the category affordable — the two-item cap does that — but it
    // is what stops a perfectly smooth session emitting two items describing
    // nothing, and what keeps `screen.name` pointing at a screen that actually
    // stuttered.
    if (window.slowFrames == 0) return;
    // The governor sheds whole tiers, and `frames` is one of the `standard`
    // ones. Asked here rather than only at construction because the shed
    // happens mid-session.
    if (gate != null && !gate!.allows(Capture.frames)) return;
    // Tiers split the emitter, never double it: `screenWindowedFrames`
    // *supersedes* the reservoir rather than adding a second emitter, or the
    // two worst windows would appear twice per session. Asked per close, not
    // once at construction, because the budget governor sheds `diagnostic`
    // whole at runtime and that must fall back to the reservoir.
    if (gate?.allows(Capture.screenWindowedFrames) ?? false) {
      _emit(window);
    } else {
      _rank(window);
    }
  }

  /// Rank descending on `(frozen_frames, slow_frames, max_total_duration_ms)`
  /// — **absolute counts, never a rate**. `slow_frame_rate` is on the payload
  /// and is the obvious first reach, but a 5-frame window with 3 slow frames
  /// scores 0.60 and would evict a 600-frame window with 200 slow frames at
  /// 0.33. Short windows are not rare — every screen change closes one — so
  /// ranking by rate would systematically surface the shortest. Counts rank by
  /// how much jank the user actually ate, which is what the two items report.
  void _rank(_FrameWindow window) {
    _held
      ..add(window)
      ..sort((a, b) {
        if (a.frozenFrames != b.frozenFrames) {
          return b.frozenFrames.compareTo(a.frozenFrames);
        }
        if (a.slowFrames != b.slowFrames) {
          return b.slowFrames.compareTo(a.slowFrames);
        }
        return b.maxTotalMs.compareTo(a.maxTotalMs);
      });
    if (_held.length > kFrameReservoirSize) _held.removeLast();
  }

  void _emit(_FrameWindow window) {
    final sink = _sink;
    if (sink == null) return;
    sink.add(
      EdgeEvent.event(
        'frame.summary',
        attributes: {
          'frame.total_frames': window.totalFrames.toString(),
          'frame.slow_frames': window.slowFrames.toString(),
          'frame.frozen_frames': window.frozenFrames.toString(),
          'frame.slow_frame_rate': (window.slowFrames / window.totalFrames)
              .toStringAsFixed(4),
          'frame.max_total_duration_ms': window.maxTotalMs.toStringAsFixed(2),
          'frame.max_build_duration_ms': window.maxBuildMs.toStringAsFixed(2),
          'frame.max_raster_duration_ms': window.maxRasterMs.toStringAsFixed(2),
          'frame.window_duration_ms': ((window.endMicros - window.startMicros) /
                  1000)
              .toStringAsFixed(2),
          // Omitted, never zeroed, when no view has reported one: a 0 Hz row is
          // indistinguishable from a real reading.
          if (window.refreshRate != null)
            'display.refresh_rate': window.refreshRate!.toStringAsFixed(1),
          // Frozen at window start, overriding the ambient snapshot: by the time
          // the reservoir flushes, the current screen is whichever one the user
          // happens to be on. A window opened before the first route push
          // carries neither key and inherits the ambient id — in an app that is
          // the launch window of the first screen, which is the screen those
          // frames belong to anyway.
          if (window.screenName != null) 'screen.name': window.screenName!,
          if (window.screenId != null) 'screen.id': window.screenId!,
        },
        // **No trace keys at all** — neither frozen nor ambient. A window spans
        // up to ten seconds and, under a two-second action TTL, routinely covers
        // several actions and the gaps between them. Freezing whichever root was
        // open at frame one attributes the whole window to an arbitrary one of
        // them; letting the ambient snapshot supply them at emit time attributes
        // it to a root that opened minutes later. Both are false precision on
        // the one event whose subject is a span of time rather than a thing the
        // user did. *A window is not an action*, and this flag with no frozen
        // copy behind it is how the wire says so.
        ownsTraceContext: true,
        // The item is sent at the flush, but it describes the window.
        occurredAt: window.start,
      ),
    );
  }

  /// Per-occurrence detail behind `frame.frozen_frames`, joinable to it on
  /// `screen.id`.
  ///
  /// Redefined from v2's `> 16.67 ms`, which was a live defect rather than a
  /// budget choice: at 60 Hz a sustained two-second stall produces ~120
  /// dropped frames, so the 100/session cap was exhausted by the session's
  /// first stall and every later one — including the one before the crash —
  /// recorded nothing.
  void _emitLongTask(double totalMs, double buildMs, double rasterMs) {
    if (!(gate?.allows(Capture.longTask) ?? false)) return;
    if (++_longTasks > kLongTaskCap) return;
    _sink?.add(
      EdgeEvent.metric(
        'long_task',
        totalMs,
        attributes: {
          'frame.build_duration_ms': buildMs.toStringAsFixed(2),
          'frame.raster_duration_ms': rasterMs.toStringAsFixed(2),
          'frame.total_duration_ms': totalMs.toStringAsFixed(2),
        },
      ),
    );
  }

  /// The display's *actual* rate, not a target — the budget above stays at
  /// 16 ms whatever this reads. Defensive because a view is not guaranteed:
  /// `views` is empty before the first frame and in a headless test.
  static double? _platformRefreshRate() {
    final views = PlatformDispatcher.instance.views;
    return views.isEmpty ? null : views.first.display.refreshRate;
  }
}

/// One screen segment's accumulators — ten scalars and two short strings, a
/// fixed shape that does not grow with session length. Three of these exist at
/// most: one open, two held.
class _FrameWindow {
  _FrameWindow({
    required this.start,
    required this.startMicros,
    required this.screenId,
    required this.screenName,
    required this.refreshRate,
  }) : endMicros = startMicros;

  /// Wall clock, for the backdated item timestamp only.
  final DateTime start;

  /// The engine's monotonic frame clock, for every elapsed measurement.
  final int startMicros;

  final String? screenId;
  final String? screenName;
  final double? refreshRate;

  int endMicros;

  /// Whether this survivor has already been sent — see [flushReservoir].
  bool emitted = false;
  int totalFrames = 0;
  int slowFrames = 0;
  int frozenFrames = 0;
  double maxTotalMs = 0;
  double maxBuildMs = 0;
  double maxRasterMs = 0;
}
