// lib/src/managers/trace_manager.dart
//
// The correlation spine (#83, spec §4/§5). Owns the one open trace root and
// hands out frozen child spans. Emits nothing and holds no sink — the pointer
// hook emits `ui.interaction`, this manager only holds — which is what keeps it
// out of `session.bindSink`'s late-binding cycle.
//
// Exactly one dependency edge: TraceManager → SessionManager, for the live
// `session.id` (the frozen-vs-live compare at inject time) and for the
// clear-on-rotation rule. `ContextManager` then merges `current()` as a second
// delegate beside the session's own attributes.

import 'identity_format.dart';
import 'session_manager.dart';

/// The four trace roots (#55). Denormalised onto every child as
/// `trace.root_type`, so "p95 HTTP latency during launch" is a single-table
/// scan rather than a join back to the root.
enum TraceRootType {
  /// Minted at init — the cold-start window.
  launch,

  /// A completed gesture (tap / long-press / swipe).
  interaction,

  /// A request that found no live root and re-rooted itself, parentless.
  request,

  /// A navigation with no live root — a deep link or a push-open.
  navigation,
}

/// The immutable carrier returned by [TraceManager.startChild].
///
/// Frozen at the synchronous call instant, *before* the caller awaits anything:
/// a request measured 509 ms cold, and reading ambient context again at send
/// time would silently reparent it onto an unrelated later tap. The event
/// describing the request must therefore be enriched from this same copy, or
/// the header on the wire and the event disagree.
class FrozenTrace {
  const FrozenTrace({
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.rootType,
    required this.sessionId,
  });

  /// W3C 32-hex.
  final String traceId;

  /// W3C 16-hex — this item's own id. A request's span id **is** the request
  /// id; there is no separate `request_id`, and no `error_id` either.
  final String spanId;

  /// W3C 16-hex — the root's span id, which is also `rum.action.id`, the sole
  /// join key. Spans hang directly off the root, so the two are the same value
  /// under two names, both of which the backend contract expects.
  final String parentSpanId;

  final TraceRootType rootType;

  /// The live session at freeze time. Carried so the inject-time mismatch
  /// compare is a field read rather than a second trip through a manager that
  /// may have rotated in between.
  final String? sessionId;

  /// The item's own trace keys. Its caller must also set
  /// `EdgeEvent.ownsTraceContext`, or the ambient snapshot wins on any key this
  /// map happens not to carry.
  Map<String, String> get attributes => {
        'trace.id': traceId,
        'rum.action.id': parentSpanId,
        'trace.root_type': rootType.name,
        'span.id': spanId,
        'parent.span.id': parentSpanId,
      };
}

/// Holds the one open trace root, expiring it lazily.
///
/// **Expiry runs in the read accessors, not in the Collector.** The freeze
/// happens inside the request override and the item describing that request
/// does not reach `Collector.add` until completion, hundreds of milliseconds
/// later — so a Collector-side check would run long after a freeze that already
/// captured an expired root, and the freeze is a read path that never passes
/// through the Collector at all.
///
/// The price, stated rather than buried: [current] and [startChild] are
/// side-effecting reads. That is safe because expiry is monotonic (a root never
/// un-expires) and idempotent, and it is unavoidable under the no-timer rule —
/// with no timer, every expiry is somebody's read.
class TraceManager {
  /// Conformed verbatim from the sibling, not re-derived: the expired-outcome
  /// ratio is a shared falsifier, comparable across the family only if the
  /// numbers match. Internal constants, never config.
  static const Duration idleWindow = Duration(seconds: 2);
  static const Duration rootCap = Duration(seconds: 10);

  final SessionManager session;

  /// Injectable clock — tests advance it to exercise expiry.
  final DateTime Function() _clock;

  String? _traceId;
  String? _rootSpanId;
  TraceRootType? _rootType;
  String? _rootSessionId;
  DateTime? _mintedAt;
  DateTime? _lastActivityAt;

  TraceManager({required this.session, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// Open a root of [rootType], superseding any root still open — mobile
  /// actions are sequential, and the second tap ends the first's claim on
  /// ambient context.
  void mint(TraceRootType rootType) {
    final now = _clock();
    _traceId = secureHex32();
    _rootSpanId = secureHex16();
    _rootType = rootType;
    _rootSessionId = session.currentSessionId;
    _mintedAt = now;
    _lastActivityAt = now;
  }

  /// The ambient trace context — **exactly the three keys** in
  /// `kAmbientTraceAttributes`, expiry already evaluated. Empty when no root is
  /// open, which is a legal state and not an error.
  ///
  /// Merged by `ContextManager.snapshot()`, so a capture hook that never
  /// touches trace context cannot forget it. That is the structural fix for the
  /// exact bug class that silently dropped seven emissions through all of v2: a
  /// hook cannot forget what it never touches.
  Map<String, String> current() {
    _expire();
    if (_traceId == null) return const {};
    return {
      'trace.id': _traceId!,
      'rum.action.id': _rootSpanId!,
      'trace.root_type': _rootType!.name,
    };
  }

  /// The one call a referenceable capture site makes — request, interaction,
  /// screen load, task completion. One synchronous call rather than four
  /// ordered steps on a hot path inside a wrapper before an await, where a
  /// wrong order is invisible in the data.
  ///
  /// It evaluates expiry, extends the root's idle window, mints the child span
  /// id, links the parent and pins the live session, and returns the lot
  /// frozen. Null means no root was open at the freeze instant — the legal
  /// unattributed case, and precisely why its caller must set
  /// `EdgeEvent.ownsTraceContext`.
  FrozenTrace? startChild() {
    _expire();
    if (_traceId == null) return null;
    _lastActivityAt = _clock();
    return FrozenTrace(
      traceId: _traceId!,
      spanId: secureHex16(),
      parentSpanId: _rootSpanId!,
      rootType: _rootType!,
      sessionId: session.currentSessionId,
    );
  }

  /// Drop the open root. Called on `AppLifecycleState.paused` — load-bearing,
  /// because Dart has no elapsed-realtime analogue and `Stopwatch` behaviour
  /// across device suspend is unverified, so a wall-clock TTL alone cannot be
  /// trusted to age out a root the user left open for a day.
  void clear() {
    _traceId = null;
    _rootSpanId = null;
    _rootType = null;
    _rootSessionId = null;
    _mintedAt = null;
    _lastActivityAt = null;
  }

  /// Idle window, hard cap, or a session rotation underneath us.
  ///
  /// The rotation check is the clear-on-rotation rule and costs no callback: a
  /// trace never spans a session, so a root whose session id no longer matches
  /// the live one is already dead, whether it aged out or not.
  void _expire() {
    if (_traceId == null) return;
    final now = _clock();
    if (_rootSessionId != session.currentSessionId ||
        now.difference(_lastActivityAt!) > idleWindow ||
        now.difference(_mintedAt!) > rootCap) {
      clear();
    }
  }
}
