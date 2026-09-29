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

/// The 16 canon event names (§2). `app.crash` rides the immediate crash rail,
/// not the batch, but is listed here for completeness.
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
/// owned by their own tickets, not by this list.
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
const Set<String> kCanonMetrics = {
  'frame_render_time',
  'memory_usage',
  'long_task',
  'resource_timing',
};

/// Attribute keys the SDK must never send — the Collector is the single source
/// of geo/tenant truth (mapping §1, injected from client IP + API key).
const Set<String> kForbiddenAttributes = {'location', 'tenant_id', 'geo'};

/// Whether a batched item of [type] (`event`/`metric`) named [name] is canon.
bool isCanonWireItem(String type, String name) => type == 'metric'
    ? kCanonMetrics.contains(name)
    : kCanonEvents.contains(name);

/// The one wire envelope (`telemetry_batch`). Both rails send this shape — the
/// batched flush and the one-item immediate crash — so a payload the queue
/// stored verbatim and drained days later is still self-describing: the item
/// carries its own context snapshot in `attributes`, and the envelope names it.
///
/// Field order is part of the canon (`type`/`timestamp`/`batch_size`/`events`).
Map<String, dynamic> telemetryBatch(List<Map<String, dynamic>> items) => {
      'type': 'telemetry_batch',
      'timestamp': DateTime.now().toIso8601String(),
      'batch_size': items.length,
      'events': items,
    };

/// A payload stored before the immediate rail was enveloped (v2.0.0 → v3) is a
/// bare wire item. Re-wrap it at drain so the crash backlog becomes deliverable
/// at the moment the envelope fix ships.
Map<String, dynamic> rewrapIfBare(Map<String, dynamic> stored) =>
    stored['type'] == 'telemetry_batch' ? stored : telemetryBatch([stored]);
