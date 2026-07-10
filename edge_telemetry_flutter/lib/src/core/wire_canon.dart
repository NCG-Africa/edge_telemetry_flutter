// lib/src/core/wire_canon.dart
//
// The family wire allowlist (eventname-envelope-mapping.md §2/§4). The Collector
// drops any batched event/metric whose name is not on these lists, so only canon
// signal reaches the wire. Capture hooks emit canon names at the source; this is
// the enforced boundary + the anchor the wire snapshot test asserts against.

/// The 12 canon event names (§2). `app.crash` rides the immediate crash rail,
/// not the batch, but is listed here for completeness.
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
};

/// The 4 canon metric names (§4).
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
