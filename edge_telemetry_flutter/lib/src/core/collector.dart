// lib/src/core/collector.dart

import '../capture/capture_hook.dart';
import '../managers/context_manager.dart';
import '../managers/session_manager.dart';
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

  Collector({
    required this.context,
    required this.session,
    required this.pipeline,
  });

  /// Sample gate. Immediate events (crash) always pass; batched events are
  /// dropped only when the session rolled sampled-out (`session.sampled=false`).
  // ponytail: default is keep-all (no `session.sampled` set) → byte-identical
  // with v1.5.2. The per-session roll that sets the flag is session work (#9).
  bool _shouldSample(EdgeEvent event) {
    if (event.priority == EventPriority.immediate) return true;
    return context.snapshot()['session.sampled'] != 'false';
  }

  @override
  void add(EdgeEvent event) {
    // Lazy idle check on the "next event" (spec #15 §2.1): may rotate the
    // session (finalize old + start new) before this event is processed.
    // Guarded internally against the bookends it re-emits here.
    session.beforeEvent();

    if (!_shouldSample(event)) return;

    // Allowlist gate: only the canon 12 events / 4 metrics reach the wire.
    // Immediate crashes (app.crash) bypass — they ride their own rail. Drops
    // happen before counters so noise/folded events don't bump session counts.
    if (event.priority != EventPriority.immediate &&
        !isCanonWireItem(event.type, event.name)) {
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
    final enriched = <String, String>{
      ...context.snapshot(),
      ...event.attributes,
    }..removeWhere((k, _) => kForbiddenAttributes.contains(k));
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

    // Two send rails: crashes (and any immediate event) bypass the batch; every
    // batched event/metric buffers in the Pipeline.
    if (event.priority == EventPriority.immediate) {
      pipeline.sendNow(wireItem);
    } else {
      pipeline.enqueue(wireItem);
    }
  }
}
