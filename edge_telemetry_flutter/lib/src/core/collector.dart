// lib/src/core/collector.dart

import 'dart:convert';

import '../capture/capture_hook.dart';
import '../crash/error_category.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/context_manager.dart';
import '../managers/session_manager.dart';
import 'attribute_policy.dart';
import 'capture_gate.dart';
import 'edge_event.dart';
import 'pipeline.dart';
import 'wire_canon.dart';

/// Per-session ceiling on emitted `ui.interaction` events (#57 D8). Auto-
/// capture runs at one to three gestures per second on a busy screen, which
/// overruns the item budget on a typical session; the sibling can decline to
/// sample because it never declared a ceiling.
///
/// **It sheds events, never roots.** `TraceManager.mint` still opens a root
/// past the cap, so every later request, crash and frame aggregate keeps its
/// attribution and only the behavioural record thins — and
/// `session.action_count`, taken at the mint, still reports every action.
const int kActionEventCap = 200;

/// Per-session ceilings on **non-fatal** `app.crash` items (#90, §11). One error
/// in a `build()` method or a loop is the flood these bound: five occurrences of
/// one fault is enough to triage it, and fifty faults is more than any session
/// has to report.
///
/// The dedup key is `exception_type` + top stack frame, and it is **client-local
/// and never sent** — the server owns crash hashing, so this is a counter key,
/// not a fingerprint. A fatal is exempt from both: it is `essential`, there is at
/// most one, and it is the item the whole rail exists for.
const int kErrorPerKeyCap = 5;
const int kErrorSessionCap = 50;

/// The single per-event gatekeeper. Every [EdgeEvent] — from a capture hook or a
/// facade API call — passes through here: sample gate, context merge, session
/// counters, then routing to the [Pipeline] (batched) or the immediate rail.
///
/// Absorbs the routing half of the v1.5.2 `JsonEventTracker`. Implements
/// [EventSink] so any [CaptureHook] can feed it directly.
class Collector implements EventSink {
  final ContextManager context;
  final SessionManager session;
  final Pipeline pipeline;

  /// Crash-scoped breadcrumb ring. When present, its entries are attached to
  /// every `app.crash` as `crash.breadcrumbs` (spec #15 §5.5) — never in the
  /// global snapshot. Optional so faked collectors can skip it.
  final BreadcrumbManager? breadcrumbs;

  /// Logs each off-canon drop by name. The counter below ships regardless —
  /// a debug-only log would not have caught v2's seven silent drops.
  final bool debugMode;

  /// The budget governor's item counter. Optional so a faked collector can skip
  /// it; when present every admitted item is counted, and crossing a ceiling
  /// sheds a whole tier at the capture hooks.
  final CaptureGate? gate;

  /// The PII policy: the one redaction hook plus the per-key cardinality cap.
  /// Optional so a faked collector can skip it.
  final AttributePolicy? policy;

  /// The batch-context hoist flip (#82). Injected so the wire seam is testable;
  /// it defaults to the compile-time [kHoistBatchContext] and is **never** a
  /// config field — see that constant for the silent-failure mode.
  final bool hoistBatchContext;

  /// `ui.interaction` events admitted this session, against [kActionEventCap].
  /// Reset by [resetPerSessionCaps] on rotation — the cap is per session, like
  /// the governor's budget.
  int _actionEvents = 0;

  /// Non-fatal `app.crash` items admitted this session, overall and per dedup
  /// key. Both reset on rotation beside the action cap.
  int _nonFatalErrors = 0;
  final Map<String, int> _errorsByKey = {};

  Collector({
    required this.context,
    required this.session,
    required this.pipeline,
    this.breadcrumbs,
    this.debugMode = false,
    this.gate,
    this.policy,
    this.hoistBatchContext = kHoistBatchContext,
  });

  /// Sample gate on the sampling axis (orthogonal to send-priority). Bypass
  /// events — crash, `session.*` bookends, `user.profile.update` — always pass;
  /// subject-to-sample events are dropped only when the session rolled
  /// sampled-out (`session.sampled=false`), so a sampled-out session drops its
  /// whole event stream coherently while still bracketing + reporting crashes.
  // ponytail: default is keep-all (no `session.sampled` set, sampleRate 1.0) →
  // byte-identical with v1.5.2. The per-session roll lives in SessionManager.
  bool _shouldSample(EdgeEvent event) {
    if (event.bypassSampling) return true;
    return context.snapshot()['session.sampled'] != 'false';
  }

  @override
  void add(EdgeEvent event) {
    // Lazy idle check on the "next event" (spec #15 §2.1): may rotate the
    // session (finalize old + start new) before this event is processed.
    // Guarded internally against the bookends it re-emits here.
    session.beforeEvent();

    // Allowlist gate: only the canon 16 events / 4 metrics reach the wire.
    // Anything on the immediate rail bypasses it — a fatal crash and the session
    // bookends, which are their own one-item batches. A **non-fatal** `app.crash`
    // batches since #90, so it does pass this gate; `app.crash` is on the canon
    // list, which is what lets it through. Drops
    // happen before the session counters so noise/folded events don't bump
    // session counts. Still a hard drop (#79) — but no longer a silent one: it
    // logs under debugMode and lands on `session.finalized` as a counted reason.
    //
    // Ahead of the sample gate on purpose: `session.finalized` bypasses sampling
    // and ships this count, so a sampled-out session must not report a confident
    // zero for drops it never looked at. (It is also the cheaper check — a set
    // lookup before `context.snapshot()`.)
    if (event.priority != EventPriority.immediate &&
        !isCanonWireItem(event.type, event.name)) {
      session.recordDropped('off_canon');
      if (debugMode) {
        print('🚫 Dropped off-canon ${event.type} "${event.name}" '
            '— not on the wire allowlist (lib/src/core/wire_canon.dart)');
      }
      return;
    }

    if (!_shouldSample(event)) return;

    // The per-session action cap: the same species of drop as the allowlist —
    // taken on the item's name, before enrichment, counted on the wire — but
    // *after* the sample gate, unlike the allowlist. A sampled-out session
    // emits no `ui.interaction` at all, so counting its gestures against the
    // cap would report a ceiling breach that never happened.
    if (event.name == 'ui.interaction' && ++_actionEvents > kActionEventCap) {
      session.recordDropped('action_cap');
      if (debugMode) {
        print('🚫 Dropped ui.interaction — past the per-session cap of '
            '$kActionEventCap events (the root was still minted)');
      }
      return;
    }

    // Counters bump before enrichment so the event's own session counts
    // include itself (matches v1.5.2 recordEvent-before-enrich ordering).
    if (event.countsToSession) {
      event.type == 'metric' ? session.recordMetric() : session.recordEvent();
    }

    // Journey counters by canon name (§2.3). app.crash counts as a crash, and
    // as a non-fatal error when is_fatal=false (all Dart errors); http.request
    // counts an HTTP hit. These feed the session.finalized summary.
    //
    // The SDK's own failures are exempt (#90): tagging them
    // `crash.source = sdk` is only half the fix — left in the counters they
    // still inflate the one error rate a consumer reads straight off the
    // bookend, with no way to subtract them.
    if (event.name == 'app.crash') {
      if (event.attributes['crash.source'] != kSdkCrashSource) {
        session.recordCrash();
        if (event.isNonFatalCrash) session.recordError();
      }
    } else if (event.name == 'http.request') {
      session.recordHttpRequest();
    }

    // The non-fatal error caps (#90), deliberately **after** the counters and so
    // unlike the action cap's position here. The precedent is
    // `session.action_count`, which is taken at the mint rather than at the
    // emission for exactly this reason: a counter that counted *sends* would
    // report 5 for a build method that threw 40 times, and read as a quiet
    // session. The count is what happened; `error_cap` on the bookend says what
    // did not ship, and the two add back to the truth.
    //
    // A fatal never reaches this gate — it is `essential`, there is at most one,
    // and it is the item the rails exist for.
    if (event.isNonFatalCrash && !_claimErrorAllowance(event)) {
      session.recordDropped('error_cap');
      if (debugMode) {
        print('🚫 Dropped non-fatal app.crash "${event.crashDedupKey}" — past '
            'the per-session caps ($kErrorPerKeyCap per fault, '
            '$kErrorSessionCap overall)');
      }
      return;
    }

    // The single wire choke point for the geo/tenant strip: every path below
    // (batched, metric, crash) sends this map, and it merges caller-supplied
    // `event.attributes` — so location/tenant_id/geo are removed here, after the
    // merge, whether they came from a global or an event attribute (mapping §1).
    final enriched = <String, String>{...context.snapshot()};

    // The fourth axis. An item that froze its own trace context at the moment
    // it describes must not have the *current* ambient keys spread underneath
    // it: a request frozen before any root was live legally carries none, and
    // an absent key cannot beat a present one. Strip first, then merge the
    // item's own attributes over the top.
    if (event.ownsTraceContext) {
      enriched.removeWhere((k, _) => kAmbientTraceAttributes.contains(k));
    }

    enriched
      ..addAll(event.attributes)
      ..removeWhere((k, _) => kForbiddenAttributes.contains(k));

    // PII, at the one place every item passes. Scoped to the item's own keys
    // — the ~30-key context snapshot is the SDK's own, and running a consumer
    // callback over all of it would be 30 callbacks per item on the UI isolate
    // for values the SDK already controls — and, within those, split by who
    // chose them (`EdgeEvent.consumerAttributes`).
    policy?.apply(enriched, event.attributes.keys,
        consumerSupplied: event.consumerAttributes);

    // Crash-scoped breadcrumb attach (spec #15 §5.5): the ring rides only on
    // `app.crash`, JSON-encoded (attributes are String-valued on the wire).
    //
    // A fatal ships the whole 50-crumb ring; a non-fatal ships the newest ten
    // (#90). An empty ring omits the key rather than sending `"[]"`.
    if (event.name == 'app.crash' && breadcrumbs != null) {
      final crumbs = breadcrumbs!.getBreadcrumbsAsJson(
          limit: event.isNonFatalCrash
              ? BreadcrumbManager.nonFatalBreadcrumbs
              : null);
      if (crumbs.isNotEmpty) enriched['crash.breadcrumbs'] = jsonEncode(crumbs);
    }

    // Backdated when the item says so — an aggregate held in a reservoir
    // describes a window that closed long before this flush.
    final timestamp = (event.occurredAt ?? DateTime.now()).toIso8601String();

    final wireItem = event.type == 'metric'
        ? {
            'type': 'metric',
            'metricName': event.name,
            'value': event.value,
            'timestamp': timestamp,
            'attributes': enriched,
          }
        : {
            // 'event' — incl. the immediate `app.crash` (unprefixed keys ride in
            // `enriched`; there is no bare `type:"error"` item on the wire in v2).
            'type': 'event',
            'eventName': event.name,
            'timestamp': timestamp,
            'attributes': enriched,
          };

    // Counted here and nowhere else: this is the one place an item is known to
    // be leaving the device, so it is the only honest input to the budget.
    gate?.recordItem();

    // Two send rails, chosen by the item: a fatal crash and the session bookends
    // go immediate; everything else — a non-fatal crash included — buffers in
    // the Pipeline.
    if (event.priority == EventPriority.immediate) {
      // The immediate rail is never hoisted — it is already its own one-item
      // batch, and the `session.*` bookends riding it are exactly where the
      // mutable session counters must still land.
      pipeline.sendNow(wireItem);
    } else {
      pipeline.enqueue(wireItem, context: _splitContextFrom(enriched));
    }
  }

  /// Start fresh allowances for every ceiling the Collector owns — the
  /// `ui.interaction` cap and the two non-fatal error caps. Bound to
  /// `SessionManager.onSessionStart` beside the governor's budget reset; all of
  /// them are per session.
  void resetPerSessionCaps() {
    _actionEvents = 0;
    _nonFatalErrors = 0;
    _errorsByKey.clear();
  }

  /// Claim one allowance for this non-fatal against [kErrorPerKeyCap] per fault
  /// and [kErrorSessionCap] overall, returning whether there was one to claim.
  ///
  /// Named for the mutation because it mutates: a caller that asks twice for one
  /// item consumes two allowances. The overall cap is checked first and, once
  /// reached, short-circuits before the key is read — past 50 the answer is no
  /// whatever the key is, so `_errorsByKey` stops growing when the gate closes.
  bool _claimErrorAllowance(EdgeEvent event) {
    if (_nonFatalErrors >= kErrorSessionCap) return false;
    final key = event.crashDedupKey;
    final seen = _errorsByKey[key] ?? 0;
    if (seen >= kErrorPerKeyCap) return false;
    _errorsByKey[key] = seen + 1;
    _nonFatalErrors++;
    return true;
  }

  /// Split the batch-level context out of [enriched] **in place** — the same map
  /// object the wire item already holds — and return the hoisted block. Mutable
  /// session counters are removed outright: they re-measure per snapshot, so
  /// they can be neither batch-scoped nor worth a copy per item.
  ///
  /// The two halves are disjoint by construction, so the server-side merge of
  /// block + item bag is byte-identical to the bag this item would have carried
  /// un-hoisted, minus those counters.
  ///
  /// Stripping the counters and building the block are one decision, not two:
  /// both halves come from `SessionManager.getSessionAttributes()`, which is
  /// all-or-nothing (empty until a session starts). So an empty block always
  /// means there were no counters there to strip — the envelope can never ship
  /// counters removed *and* no block to pay for it.
  Map<String, String> _splitContextFrom(Map<String, String> enriched) {
    if (!hoistBatchContext) return const {};
    final hoisted = <String, String>{};
    enriched.removeWhere((key, value) {
      if (kMutableSessionCounters.contains(key)) return true;
      if (!isHoistedContextKey(key)) return false;
      hoisted[key] = value;
      return true;
    });
    return hoisted;
  }
}
