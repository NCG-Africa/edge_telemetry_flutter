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

/// Every event name this SDK emits — the catalogue's canonical names
/// (`edge_telemetry_processor_go/docs/catalogue/`, pinned in
/// `catalogue.version`). 4.2.0 converged on the catalogue (#127): the legacy
/// names (`page_load`, `app_lifecycle`, `network_change`, `custom_event`,
/// `memory_usage`, `long_task`, ANR/hang as `app.crash` causes) are gone from
/// the device and resolve through the processor's aliases for older builds.
///
/// `app.crash` / `app.anr` / `app.hang` take the immediate rail and skip this
/// gate; `app.error` and an unhandled Dart `app.crash` batch and pass it.
const Set<String> kCanonEvents = {
  'session.started',
  'session.finalized',
  'app.lifecycle',
  'app.start',
  'navigation',
  'screen.duration',
  'screen.load',
  'http.request',
  'network.change',
  'user.profile.update',
  'custom.event',
  'app.crash',
  'app.error',
  'app.anr',
  'app.hang',
  'ui.interaction',
  'frame.summary',
  'memory.usage',
  'task.complete',
};

/// The metric names this SDK emits. A host's `trackMetric` rides
/// `custom.metric` with its own name in `metric.name`.
const Set<String> kCanonMetrics = {'custom.metric', 'perf.long_task'};

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
///
/// `app.start.*` is not identity: it is the `app.start` event's own keys.
bool isEnvelopeIdentityKey(String key) =>
    key == 'device.id' ||
    (key.startsWith('app.') && !key.startsWith('app.start.')) ||
    key.startsWith('sdk.');

/// Whether a batched item of [type] (`event`/`metric`) named [name] is canon.
bool isCanonWireItem(String type, String name) =>
    type == 'metric'
        ? kCanonMetrics.contains(name)
        : kCanonEvents.contains(name);

/// The batch contract version (R11): one semver shared by every SDK in the
/// family, so it is **not** [kSdkVersion]. Minor = additive, major = breaking.
const String kContractVersion = '4.3.0';

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

/// [time] as UTC RFC 3339 with a `Z` — every wire timestamp, envelope, item
/// or attribute. A local `toIso8601String()` carries no offset and fails the
/// catalogue's RFC 3339 check.
String utc(DateTime time) => time.toUtc().toIso8601String();

/// Attribute keys the catalogue types as `int` (`attributes.yaml`). Attributes
/// are `String` inside the SDK; [typedAttributes] converts these at the wire.
const Set<String> kIntAttributes = {
  'app.start.duration_ms',
  'app.start.sdk_init_ms',
  'anr.duration_ms',
  'device.android_sdk',
  'frame.total_frames',
  'frame.slow_frames',
  'frame.frozen_frames',
  'frame.window_duration_ms',
  'hang.duration_ms',
  'http.status_code',
  'http.duration_ms',
  'http.request_size',
  'http.response_size',
  'http.dns_ms',
  'http.connect_ms',
  'http.queue_ms',
  'http.download_ms',
  'http.redirect_count',
  'screen.duration_ms',
  'screen.load.first_frame_ms',
  'screen.load.settled_ms',
  'session.duration_ms',
  'session.event_count',
  'session.metric_count',
  'session.screen_count',
  'session.total_sessions',
  'session.error_count',
  'session.crash_count',
  'session.http_request_count',
  'session.action_count',
  'session.dropped_item_count',
  'session.cardinality_capped_count',
  'session.last_screen_duration_ms',
  'span.duration_ms',
  'user.profile_version',
};

/// Attribute keys the catalogue types as `float`.
const Set<String> kFloatAttributes = {
  'device.battery_level',
  'device.text_scale_factor',
  'display.refresh_rate',
  'frame.slow_frame_rate',
  'frame.max_build_duration_ms',
  'frame.max_raster_duration_ms',
  'frame.max_total_duration_ms',
  'frame.build_duration_ms',
  'frame.raster_duration_ms',
  'memory.usage_mb',
};

/// Attribute keys the catalogue types as `bool`.
const Set<String> kBoolAttributes = {
  'device.battery_charging',
  'device.power_save',
  'device.reduce_motion',
  'http.success',
  'http.url_redacted',
  'http.connection_reused',
  'navigation.has_arguments',
  'session.is_first_session',
  'session.recovered',
  'session.sampled',
  'trace.root_expired',
};

/// The item's attributes as the catalogue types them: the keys in
/// [kIntAttributes], [kFloatAttributes] and [kBoolAttributes] become JSON
/// numbers and booleans, every other key stays a string. A value that does not
/// parse stays a string rather than being dropped, so a bug shows up as a
/// conformance failure instead of a silent gap.
// ponytail: one key table, not a typed attribute model through the SDK. Add a
// key here when the catalogue types it; the golden conformance check fails
// until you do.
Map<String, Object> typedAttributes(Map<String, String> attributes) => {
  for (final MapEntry(:key, :value) in attributes.entries)
    key: _typed(key, value),
};

Object _typed(String key, String value) {
  if (kIntAttributes.contains(key)) {
    return int.tryParse(value) ?? double.tryParse(value)?.round() ?? value;
  }
  if (kFloatAttributes.contains(key)) return double.tryParse(value) ?? value;
  if (kBoolAttributes.contains(key)) {
    return switch (value) {
      'true' => true,
      'false' => false,
      _ => value,
    };
  }
  return value;
}

/// The one wire envelope, contract 4.x (R3). Both rails send this shape —
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

/// Re-stamp a 4.x envelope's `timestamp` to now (R13) — called on every POST
/// attempt, so a retried, queued or drained batch carries its *send* time,
/// never the time it was built or stored. Everything else is sent verbatim,
/// including a persisted crash batch's own build identity (R14).
///
/// A legacy envelope (no `contract_version`: a 3.x batch, or a v2 bare item
/// [rewrapIfBare] wrapped) is left as stored — the processor treats its
/// offset-less local time as a known limit, and re-stamping it would mix two
/// clocks in one legacy batch.
Map<String, dynamic> stampForSend(Map<String, dynamic> batch) {
  if (batch['contract_version'] != null) batch['timestamp'] = utcNow();
  return batch;
}

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
