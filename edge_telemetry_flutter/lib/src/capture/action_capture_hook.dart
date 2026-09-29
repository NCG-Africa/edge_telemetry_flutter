// lib/src/capture/action_capture_hook.dart

import 'dart:async';

import 'package:flutter/gestures.dart';

import '../core/capture_gate.dart';
import '../core/config/collection_tier.dart';
import '../core/edge_event.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/session_manager.dart';
import '../managers/trace_manager.dart';
import 'capture_hook.dart';

/// Where `ui.target` came from. The **key** is conformed to the sibling; the
/// **values** are Flutter's, because the sibling's (`track_tap` / `test_tag` /
/// `content_description` / `text`) name sources Flutter does not have. The
/// divergence is recorded in the family change-request packet rather than
/// discovered downstream — the same class of finding as the three
/// `traceparent.outcome` vocabularies.
///
/// Only [trackAction] and [none] are reachable today: the other two read the
/// semantics tree, which is off by default because enabling it puts a
/// semantics flush in the frame pipeline for the app's whole life. They ship
/// as values now so the enum is the family record of what Flutter's key means,
/// and the naming chain that produces them lands with the semantics tier.
enum UiNameSource {
  trackAction('track_action'),
  semanticsIdentifier('semantics_identifier'),
  semanticsLabel('semantics_label'),
  none('none');

  const UiNameSource(this.wire);

  /// The wire value of `ui.name_source`.
  final String wire;
}

/// The gestures that mint a root, conformed to the sibling's set.
enum _GestureKind {
  tap('tap'),
  longPress('long_press'),
  swipe('swipe');

  const _GestureKind(this.wire);
  final String wire;
}

/// One pointer in flight, from down to up.
class _PointerTrack {
  _PointerTrack(this.downAt, this.origin, this.velocity);

  final Duration downAt;
  final Offset origin;
  final VelocityTracker velocity;

  /// Furthest the pointer ever got from [origin] — **not** its net
  /// displacement, which is what the framework's own recognizers latch on. A
  /// drag that rubber-bands back to where it started ends within the slop
  /// while never having been a tap.
  double maxTravel = 0;

  void sample(Offset position) {
    final travelled = (position - origin).distance;
    if (travelled > maxTravel) maxTravel = travelled;
  }
}

/// Captures real user behaviour without asking a consumer to annotate two
/// hundred widgets: a **global pointer route** sees every pointer event app-
/// wide, and every completed gesture in the conformed set — tap, long-press,
/// swipe — mints an `interaction` trace root and emits one `ui.interaction`.
///
/// Three things about it are load-bearing:
///
/// **Minted at pointer-up.** The route is raw — there is no confirmation stage
/// to wait on, so pointer-up is both the only candidate and the correct one:
/// a request fired from `onTap` lands under *this* root rather than the
/// previous one. It also costs nothing per frame; the route is only walked
/// when a pointer moves.
///
/// **The classifier is hand-rolled against the framework's own constants**
/// (`kTouchSlop`, `kLongPressTimeout`, `kMinFlingVelocity`), because
/// `addGlobalRoute` delivers raw pointer events and none of `GestureDetector`'s
/// collapsing. `kMinFlingVelocity` is the entire defence: a classifier that
/// called any move-then-up a swipe would mint a root on **every scroll stop**,
/// and supersede-on-next-action makes that actively destructive — it would
/// silently reparent the next request onto a scroll. Everything that is
/// neither tap, long-press nor fling mints nothing and emits nothing.
///
/// **The event is emitted on a microtask.** Mint and emit would otherwise
/// happen in the same synchronous task, so a `trackAction` call from `onTap`
/// would land *after* the event was already buffered — leaving the root named
/// and the event unnamed, which is the split identity the naming call exists
/// to prevent. The framework routes the pointer event before it sweeps the
/// gesture arena (`GestureBinding.handleEvent`), so one microtask is exact and
/// bounded. Stated limit: a handler that awaits before calling `trackAction`
/// misses the window and names only the root.
///
/// **Coordinates are deliberately absent.** `ui.x` / `ui.y` ship only in the
/// semantics tier — the same tier that can read `isObscured` and therefore
/// suppress them over a PIN pad — and that tier is not built yet. Shipping
/// them here would mean raw coordinates over password fields with no
/// suppression at all, which is strictly worse than the sibling in the one
/// area the sibling calls a compliance requirement.
class ActionCaptureHook implements CaptureHook {
  final TraceManager trace;
  final SessionManager session;

  /// One breadcrumb per emitted interaction — what the user tapped before the
  /// crash is the highest-value trail there is. Noted rather than fixed: the
  /// ring is 20 slots against the sibling's 50, so a busy screen evicts
  /// navigation and network crumbs faster than it used to.
  final BreadcrumbManager? breadcrumbs;

  /// Emission-level gate for `Capture.swipes` only. The hook as a whole is
  /// started behind `Capture.actions`; swipes are the highest-volume, lowest-
  /// value member of the set, so their *emission* is tiered — the root is
  /// still minted, so attribution survives the tier exactly as it survives the
  /// cap.
  final CaptureGate? gate;

  final Map<int, _PointerTrack> _inFlight = {};

  EventSink? _sink;

  ActionCaptureHook({
    required this.trace,
    required this.session,
    this.breadcrumbs,
    this.gate,
  });

  @override
  DisposeHandle start(EventSink sink) {
    _sink = sink;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
    return () {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);
      _inFlight.clear();
    };
  }

  void _onPointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _inFlight[event.pointer] = _PointerTrack(
        event.timeStamp,
        event.position,
        VelocityTracker.withKind(event.kind)
          ..addPosition(event.timeStamp, event.position),
      );
    } else if (event is PointerMoveEvent) {
      _inFlight[event.pointer]
        ?..velocity.addPosition(event.timeStamp, event.position)
        ..sample(event.position);
    } else if (event is PointerUpEvent) {
      final track = _inFlight.remove(event.pointer);
      if (track == null) return;
      track.velocity.addPosition(event.timeStamp, event.position);
      track.sample(event.position);
      _completed(track, event);
    } else if (event is PointerCancelEvent) {
      _inFlight.remove(event.pointer);
    }
  }

  /// Classify, mint, then emit one microtask later.
  void _completed(_PointerTrack track, PointerUpEvent up) {
    final velocity = track.velocity.getVelocity().pixelsPerSecond;

    final _GestureKind kind;
    if (track.maxTravel < kTouchSlop) {
      kind = up.timeStamp - track.downAt < kLongPressTimeout
          ? _GestureKind.tap
          : _GestureKind.longPress;
    } else if (velocity.distance >= kMinFlingVelocity) {
      kind = _GestureKind.swipe;
    } else {
      // A scroll coming to a stop. Mints nothing, emits nothing.
      return;
    }

    trace.mint(TraceRootType.interaction);

    // Swipes fail closed: no gate, no swipe event. Diagnostic captures are
    // off by default, so an absent gate must not be the one path that turns
    // one on.
    if (kind == _GestureKind.swipe &&
        !(gate?.allows(Capture.swipes) ?? false)) {
      return;
    }

    // Frozen at the mint, not read at emit. The event is emitted a microtask
    // later, and two pointer-ups can complete inside one task (multi-touch, a
    // fast double tap) — the second supersedes the first, so an ambient read
    // at emit time would ship this gesture's span id beside the *next*
    // gesture's trace. `ui.interaction` describes the root, so its span id is
    // the action id; owning the context is what makes the Collector strip the
    // live keys instead of spreading them underneath.
    final frozen = trace.current();
    final screen = session.currentScreenName;
    final direction =
        kind == _GestureKind.swipe ? _directionOf(velocity) : null;

    scheduleMicrotask(() {
      // Read after any synchronous `trackAction` from the tapped handler.
      final name = trace.rootName;
      final attributes = <String, String>{
        ...frozen,
        if (frozen['rum.action.id'] != null)
          'span.id': frozen['rum.action.id']!,
        'ui.type': kind.wire,
        if (direction != null) 'ui.direction': direction,
        if (screen != null) 'ui.screen': screen,
        'ui.name_source':
            (name == null ? UiNameSource.none : UiNameSource.trackAction).wire,
        if (name != null) 'ui.target': name,
      };
      breadcrumbs?.addUserAction(name ?? kind.wire, data: {
        'ui.type': kind.wire,
        if (screen != null) 'ui.screen': screen,
      });
      _sink?.add(EdgeEvent.event('ui.interaction',
          attributes: attributes, ownsTraceContext: true));
    });
  }

  /// The fling's exit direction — the velocity vector, not the down-to-up
  /// delta, so a flick back over its own start still reads as the way it left.
  String _directionOf(Offset velocity) => velocity.dx.abs() >= velocity.dy.abs()
      ? (velocity.dx > 0 ? 'right' : 'left')
      : (velocity.dy > 0 ? 'down' : 'up');
}
