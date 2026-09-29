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
  ///
  /// **Null on a root.** A parentless `request` root (#86) is its own root, and
  /// the contract says `parent.span.id` is children-only and absent on roots —
  /// so the key is omitted rather than self-referential, and [actionId] falls
  /// back to this item's own span id.
  final String? parentSpanId;

  final TraceRootType rootType;

  /// The live session at freeze time. Carried so the inject-time mismatch
  /// compare is a field read rather than a second trip through a manager that
  /// may have rotated in between.
  final String? sessionId;

  /// The sole join key: the root's span id — which, on a root, is its own.
  String get actionId => parentSpanId ?? spanId;

  /// The item's own trace keys. Its caller must also set
  /// `EdgeEvent.ownsTraceContext`, or the ambient snapshot wins on any key this
  /// map happens not to carry.
  Map<String, String> get attributes => {
        'trace.id': traceId,
        'rum.action.id': actionId,
        'trace.root_type': rootType.name,
        'span.id': spanId,
        if (parentSpanId != null) 'parent.span.id': parentSpanId!,
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
  String? _rootName;
  TraceRootType? _rootType;
  String? _rootSessionId;
  DateTime? _mintedAt;
  DateTime? _lastActivityAt;
  bool _expiredRoot = false;

  TraceManager({required this.session, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// Open a root of [rootType], superseding any root still open — mobile
  /// actions are sequential, and the second tap ends the first's claim on
  /// ambient context.
  ///
  /// Counts an action unconditionally (#71 D4): `session.action_count` counts
  /// **roots minted**, not events emitted, so the `ui.interaction` cap can
  /// never quietly deflate it — a busy session reads as "400 actions, 100
  /// recorded" rather than as a quiet one. Every root type counts, launch
  /// included; the count is of roots, and that is what keeps it checkable
  /// against the emitted events without a second definition.
  void mint(TraceRootType rootType) {
    final now = _clock();
    _traceId = secureHex32();
    _rootSpanId = secureHex16();
    _rootName = null;
    _rootType = rootType;
    _rootSessionId = session.currentSessionId;
    _mintedAt = now;
    _lastActivityAt = now;
    session.recordAction();
  }

  /// `trackAction(name)`: name the open root, minting one if none is live.
  ///
  /// It **emits nothing** — the sibling shipped a helper that emitted its own
  /// event and reversed it, because an adopting app then got two events for
  /// one tap across two differently-named schemas. The pointer hook's
  /// `ui.interaction` is the one event; this call only decides what it is
  /// called, which is why the pointer hook emits on a microtask (a naming call
  /// made synchronously from `onTap` still lands first).
  ///
  /// Minting when nothing is live is the navigation-root rule verbatim, and it
  /// is what makes `trackAction('nightly_sync')` from a timer work instead of
  /// silently no-op'ing.
  void nameCurrent(String name) {
    _expire();
    if (_traceId == null) mint(TraceRootType.interaction);
    _rootName = name;
    _lastActivityAt = _clock();
  }

  /// The open root's name, or null when it is unnamed or nothing is open.
  /// Read by the pointer hook one microtask after the mint.
  String? get rootName {
    _expire();
    return _rootName;
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

  /// Whether the **most recent** expiry evaluation aged a root out.
  ///
  /// This is the carrier for `injected_expired`'s TTL half: [startChild]
  /// returns null both when a root aged out and when none was ever open, and
  /// those are different outcomes on the wire. It is scoped to the one
  /// evaluation rather than to the session, so the request *after* the expired
  /// one reads as unattributed — which is what the sibling reports, and the
  /// expired-outcome ratio is only a shared falsifier if the numbers match.
  bool get rootExpired => _expiredRoot;

  /// A parentless `request` root: the request is its own root, so it mints a
  /// trace and a span and carries no `parent.span.id`.
  ///
  /// Deliberately **not** [mint]: this root is not ambient (nothing else should
  /// hang off it) and it is not a user action, so it must not bump
  /// `session.action_count`. It lives here rather than at the call site so that
  /// every trace and span id in the SDK is minted in this one file.
  FrozenTrace startRequestRoot() => FrozenTrace(
        traceId: secureHex32(),
        spanId: secureHex16(),
        parentSpanId: null,
        rootType: TraceRootType.request,
        sessionId: session.currentSessionId,
      );

  /// Whether [frozen] still belongs to the live session.
  ///
  /// A trace never spans a session, and the half that bites is a request frozen
  /// in S1 whose completion lands in S2: it would otherwise emit S1's
  /// `trace.id` beside S2's `session.id` — the invariant dying quietly on
  /// precisely the requests that matter most, the ones in flight when the app
  /// came back. Asked here rather than by reaching through to [session], which
  /// keeps this manager's one dependency edge its own.
  bool sessionMatches(FrozenTrace frozen) =>
      frozen.sessionId == session.currentSessionId;

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
    _rootName = null;
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
    // Scoped to this evaluation: see [rootExpired].
    _expiredRoot = false;
    if (_traceId == null) return;
    final now = _clock();
    if (_rootSessionId != session.currentSessionId ||
        now.difference(_lastActivityAt!) > idleWindow ||
        now.difference(_mintedAt!) > rootCap) {
      clear();
      _expiredRoot = true;
    }
  }
}
