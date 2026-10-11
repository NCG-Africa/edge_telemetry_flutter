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

import 'sdk_version.dart';

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

/// Whether [key] is a per-item copy of envelope identity (R1): `device.id`,
/// any `app.*`, any `sdk.*`. The Collector strips these from every item —
/// identity lives in the envelope only, so whatever set them (the device-info
/// bag, a consumer global, an event attribute) never reaches the wire. Every
/// other `device.*` key (model, `device.platform`, the fault bundle) stays.
bool isEnvelopeIdentityKey(String key) =>
    key == 'device.id' || key.startsWith('app.') || key.startsWith('sdk.');

/// Whether a batched item of [type] (`event`/`metric`) named [name] is canon.
bool isCanonWireItem(String type, String name) =>
    type == 'metric'
        ? kCanonMetrics.contains(name)
        : kCanonEvents.contains(name);

/// The batch contract version (R11): one semver shared by every SDK in the
/// family, so it is **not** [kSdkVersion]. Minor = additive, major = breaking.
const String kContractVersion = '4.0.0';

/// Who sent a batch (R1, R9): the root `device_id` and the `app` block.
/// Captured once at init — never read from the mutable global bag, so a
/// consumer global cannot override it.
typedef BatchIdentity = ({String deviceId, Map<String, String> app});

/// The envelope `app` block (R3), in canon key order. An empty or null [name],
/// [version] or [buildNumber] is **omitted**, never sent as `""` (R15) — the
/// processor stores `'unknown'` for a missing one.
Map<String, String> appIdentity({
  String? name,
  required String packageName,
  required String platform,
  String? version,
  String? buildNumber,
}) => {
  if (name != null && name.isNotEmpty) 'name': name,
  'package_name': packageName,
  'platform': platform,
  if (version != null && version.isNotEmpty) 'version': version,
  if (buildNumber != null && buildNumber.isNotEmpty)
    'build_number': buildNumber,
};

/// UTC RFC 3339 with a `Z` (R13). Local time with no offset — what v3 sent —
/// skews the server's `received_at − timestamp` by the device's time zone.
String utcNow() => DateTime.now().toUtc().toIso8601String();

/// The one wire envelope, contract 4.0.0 (R3). Both rails send this shape —
/// the batched flush and the one-item immediate crash.
///
/// Closed at exactly these eight keys, in this order. There is no `context`
/// block and no `clock_skew_ms` (R5, R6): context rides each item's
/// `attributes`, and skew is derived server-side as `received_at − timestamp`.
/// Identity lives here and only here (R1); the Collector strips per-item
/// copies.
Map<String, dynamic> telemetryBatch(
  List<Map<String, dynamic>> items,
  BatchIdentity identity,
) => {
  'type': 'telemetry_batch',
  'contract_version': kContractVersion,
  'timestamp': utcNow(),
  'batch_size': items.length,
  'device_id': identity.deviceId,
  'sdk': const {'name': 'flutter', 'version': kSdkVersion},
  'app': identity.app,
  'events': items,
};

/// A payload stored before the immediate rail was enveloped (v2.0.0 → v3) is a
/// bare wire item. Re-wrap it at drain so the crash backlog becomes deliverable
/// at the moment the envelope fix ships.
///
/// The bare item still carries its own per-event identity, so it is wrapped as
/// a **legacy** envelope (no `contract_version`), which the processor
/// normalizes from per-event attributes.
Map<String, dynamic> rewrapIfBare(Map<String, dynamic> stored) =>
    stored['type'] == 'telemetry_batch'
        ? stored
        : {
          'type': 'telemetry_batch',
          'timestamp': stored['timestamp'] ?? utcNow(),
          'batch_size': 1,
          'events': [stored],
        };
