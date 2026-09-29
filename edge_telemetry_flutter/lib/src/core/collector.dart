// lib/src/core/collector.dart

import 'dart:convert';

import '../capture/capture_hook.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/context_manager.dart';
import '../managers/session_manager.dart';
import 'capture_gate.dart';
import 'edge_event.dart';
import 'pipeline.dart';
import 'wire_canon.dart';

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

  /// The batch-context hoist flip (#82). Injected so the wire seam is testable;
  /// it defaults to the compile-time [kHoistBatchContext] and is **never** a
  /// config field — see that constant for the silent-failure mode.
  final bool hoistBatchContext;

  Collector({
    required this.context,
    required this.session,
    required this.pipeline,
    this.breadcrumbs,
    this.debugMode = false,
    this.gate,
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
    // Immediate crashes (app.crash) bypass — they ride their own rail. Drops
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

    // Counters bump before enrichment so the event's own session counts
    // include itself (matches v1.5.2 recordEvent-before-enrich ordering).
    if (event.countsToSession) {
      event.type == 'metric' ? session.recordMetric() : session.recordEvent();
    }

    // Journey counters by canon name (§2.3). app.crash counts as a crash, and
    // as a non-fatal error when is_fatal=false (all Dart errors); http.request
    // counts an HTTP hit. These feed the session.finalized summary.
    if (event.name == 'app.crash') {
      session.recordCrash();
      if (event.attributes['is_fatal'] == 'false') session.recordError();
    } else if (event.name == 'http.request') {
      session.recordHttpRequest();
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

    // Crash-scoped breadcrumb attach (spec #15 §5.5): the ring rides only on
    // `app.crash`, JSON-encoded (attributes are String-valued on the wire).
    if (event.name == 'app.crash' && breadcrumbs != null) {
      final crumbs = breadcrumbs!.getBreadcrumbsAsJson();
      if (crumbs.isNotEmpty) enriched['crash.breadcrumbs'] = jsonEncode(crumbs);
    }

    final timestamp = DateTime.now().toIso8601String();

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

    // Two send rails: crashes (and any immediate event) bypass the batch; every
    // batched event/metric buffers in the Pipeline.
    if (event.priority == EventPriority.immediate) {
      // The immediate rail is never hoisted — it is already its own one-item
      // batch, and the `session.*` bookends riding it are exactly where the
      // mutable session counters must still land.
      pipeline.sendNow(wireItem);
    } else {
      pipeline.enqueue(wireItem, context: _splitContextFrom(enriched));
    }
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
