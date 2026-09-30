// lib/src/core/wire_canon.dart
//
// The family wire allowlist (eventname-envelope-mapping.md §2/§4). The Collector
// drops any batched event/metric whose name is not on these lists, so only canon
// signal reaches the wire. Capture hooks emit canon names at the source; this is
// the enforced boundary + the anchor the wire snapshot test asserts against.
//
// The drop is a hard drop and stays one — it is the only device-side guard
// against an unbudgeted emitter. From v3 it is no longer *silent*: see
// `Collector.add`, which logs under `debugMode` and bumps a session-scoped
// dropped-item counter that ships on `session.finalized`.

import 'clock_skew.dart';

/// The 16 canon event names (§2). `app.crash` takes **either** rail — a fatal
/// goes immediate and skips this gate, a non-fatal batches and passes it (#90) —
/// so its presence on this list is load-bearing, not completeness.
///
/// v3 adds four (#79): `ui.interaction`, `frame.summary`, `screen.load`,
/// `task.complete`. Deliberately **not** added:
/// - `memory_pressure` / `storage_usage` — struck off the sibling's
///   "Unsupported Events — NOT processed by the backend" list.
/// - `app.anr` / `app.hang` — both already ship as `cause` values on the
///   unified `app.crash` event.
///
/// `user.interaction` and `screen.duration` stay on the list because a canon
/// name is never removed. Whether either is still emitted — and the deprecation
/// annotations, changelog line and removal version that go with stopping — is
/// owned by their own tickets, not by this list. `screen.duration` stopped being
/// emitted in v3 (#88, removal v4.0.0): the same measurement rides `navigation`
/// as `screen.previous_duration_ms`, so a navigation is one item, not two.
const Set<String> kCanonEvents = {
  'session.started',
  'session.finalized',
  'app_lifecycle',
  'page_load',
  'navigation',
  'screen.duration',
  'http.request',
  'user.interaction',
  'network_change',
  'user.profile.update',
  'custom_event',
  'app.crash',
  // v3 (#79)
  'ui.interaction',
  'frame.summary',
  'screen.load',
  'task.complete',
};

/// The 4 canon metric names (§4). v3 adds none — the ceiling is 0 new metrics.
/// `frame_render_time` and `resource_timing` stay listed for the same reason as
/// above: the name is kept, the emission is their own tickets' business.
///
/// `frame_render_time` stopped being emitted in v3 (#89, removal v4.0.0): a
/// per-frame metric at 60–120 Hz became a windowed `frame.summary` event, and
/// the build/raster split it carried rides there as two max-duration keys.
/// `long_task` keeps its name and its slot but **changes population** — v2
/// rows were frames over 16.67 ms, v3 rows are frozen frames over 700 ms, and
/// it is `diagnostic`-only, so a default-config consumer now gets none.
const Set<String> kCanonMetrics = {
  'frame_render_time',
  'memory_usage',
  'long_task',
  'resource_timing',
};

/// Attribute keys the SDK must never send — the Collector is the single source
/// of geo/tenant truth (mapping §1, injected from client IP + API key).
const Set<String> kForbiddenAttributes = {'location', 'tenant_id', 'geo'};

/// The ambient trace keys `ContextManager` merges from `TraceManager.current()`
/// while a root is open — and the exact set `Collector.add` strips from an item
/// that carries its own frozen trace context (`EdgeEvent.ownsTraceContext`).
///
/// **Three, pointedly not five.** `span.id` and `parent.span.id` are minted per
/// referenceable item and are *never* ambient, so they need no stripping —
/// listing them here would teach a future reader that the snapshot carries
/// them. The strip exists because absence cannot beat presence in a spread: a
/// request frozen before any root was live legally carries no trace keys, and
/// without an explicit strip the ambient snapshot would stamp a later tap onto
/// it — claiming a request was caused by a tap 50 ms after it started, on the
/// same row whose outcome says unattributed.
const Set<String> kAmbientTraceAttributes = {
  'trace.id',
  'rum.action.id',
  'trace.root_type',
};

/// Whether a batched item of [type] (`event`/`metric`) named [name] is canon.
bool isCanonWireItem(String type, String name) => type == 'metric'
    ? kCanonMetrics.contains(name)
    : kCanonEvents.contains(name);

/// The one wire envelope (`telemetry_batch`). Both rails send this shape — the
/// batched flush and the one-item immediate crash — so a payload the queue
/// stored verbatim and drained days later is still self-describing: the item
/// carries its own context snapshot in `attributes`, and the envelope names it.
///
/// Field order is part of the canon
/// (`type`/`timestamp`/`batch_size`/[`clock_skew_ms`]/[`context`]/`events`).
/// [context] is the hoisted block (#82), omitted entirely while
/// [kHoistBatchContext] is off; `clock_skew_ms` is omitted until the first
/// successful POST of the launch has a `Date` header to measure against. With
/// the hoist off and no skew recorded yet, the envelope is byte-identical to
/// v2's.
Map<String, dynamic> telemetryBatch(
  List<Map<String, dynamic>> items, {
  Map<String, String> context = const {},
}) =>
    {
      'type': 'telemetry_batch',
      'timestamp': DateTime.now().toIso8601String(),
      'batch_size': items.length,
      if (recordedClockSkewMs != null) 'clock_skew_ms': recordedClockSkewMs,
      if (context.isNotEmpty) 'context': context,
      'events': items,
    };

// ==================== BATCH CONTEXT HOIST (#82) ====================

/// The internal flip for the batch-level context hoist. **Default off, and
/// never a config field** — a consumer must not be able to turn on a wire shape
/// the server cannot read.
///
/// Unlike gzip, this fails *silently* if it ships before the processor-side
/// merge: an unknown top-level block is dropped, every item arrives stripped of
/// its identity, and every session lands with an empty `session.id` —
/// corruption, not a dead letter. So it flips in the release *after* the merge
/// lands, and only then.
///
/// If the merge never lands, v3 ships with this `false`: every item keeps its
/// own full bag, the wire stays byte-identical to v2, and the only cost is that
/// the un-hoisted byte ceilings in the budget go unmet (a typical session
/// measures 358 KB against a 120 KB ceiling; an item is 1,467 B, not 308 B).
const bool kHoistBatchContext = false;

/// Session keys that *identify* the session rather than measure it — constant
/// for the session's whole life, so they hoist.
const Set<String> kHoistedSessionKeys = {
  'session.id',
  'session.start_time',
  'session.is_first_session',
  'session.total_sessions',
  'session.sampled',
};

/// Mutable session counters. They re-measure on every snapshot, so they can be
/// neither batch-scoped nor worth a copy per item: under the hoist they **leave
/// the wire** on batched items. The two session bookends still carry them —
/// those ride the immediate rail, which is never hoisted.
const Set<String> kMutableSessionCounters = {
  'session.duration_ms',
  'session.event_count',
  'session.metric_count',
  'session.error_count',
  'session.crash_count',
  'session.http_request_count',
  'session.action_count',
  'session.screen_count',
  'session.visited_screens',
};

/// Whether [key] belongs in the batch-level context block: static device / app
/// / SDK identity, the user id, session identity, and the live-but-batch-scoped
/// values — `network.type` plus the `device.` keys `ContextManager` re-reads
/// per snapshot (`platform_brightness` always, `text_scale_factor` and
/// `reduce_motion` when `captureAccessibilityContext` is on).
///
/// Flat dotted spelling is load-bearing: the server-side merge is a plain map
/// merge, so each row's attribute bag comes out byte-identical to today's and
/// no existing query, typed column or index changes. Consumer-supplied globals
/// are deliberately *not* hoisted — their key names are arbitrary, so they
/// cannot be classified, and leaving them per-item keeps the merge exact.
///
// ponytail: prefix match, not an explicit set — `device.*` is open-ended
// (device_info_plus mints keys per platform), so no set could stay complete.
// Ceiling: a *per-item* attribute minted under `device.`/`app.`/`sdk.` would be
// silently batch-scoped. Today none exists (`app.crash` keys are unprefixed on
// purpose); add an exception set here the day one does.
bool isHoistedContextKey(String key) =>
    key.startsWith('device.') ||
    key.startsWith('app.') ||
    key.startsWith('sdk.') ||
    key == 'user.id' ||
    key == 'network.type' ||
    kHoistedSessionKeys.contains(key);

/// A payload stored before the immediate rail was enveloped (v2.0.0 → v3) is a
/// bare wire item. Re-wrap it at drain so the crash backlog becomes deliverable
/// at the moment the envelope fix ships.
Map<String, dynamic> rewrapIfBare(Map<String, dynamic> stored) =>
    stored['type'] == 'telemetry_batch' ? stored : telemetryBatch([stored]);
