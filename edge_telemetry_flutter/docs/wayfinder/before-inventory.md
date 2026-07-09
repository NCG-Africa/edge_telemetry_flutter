# Before-Inventory — `edge_telemetry_flutter` (current state)

> Spec appendix. The complete "before" state the v2 refactor spec starts from.
> Companion to [`family-alignment-reference.md`](./family-alignment-reference.md) (the "after" target).
> Source: code audit 2026-07-09, barrel `lib/edge_telemetry_flutter.dart` (1251 lines) + managers/monitors.
> Divergence flags (⚠️/❌) mark where today diverges from the family canon; alignment decisions live in map tickets #4–#8.

## 1. Events emitted (18)

All names are current/divergent. `→` shows the family-canon target from the reference doc §2.

| Current eventName | Trigger | Key attributes | Align to |
|---|---|---|---|
| `telemetry.initialized` | once in `_setup()` (barrel:222) | feature toggles, `json_format`, init ts | (internal; drop or `custom_event`) |
| `http.request` | every HTTP completes (barrel:285) | `http.url/method/status_code/duration_ms/success/error/response_size` | ✅ `http.request` |
| `http.error` | HTTP status outside 200–399 (barrel:301) | http.* + `error.type=http_error`, `error.category` | ⚠️ fold into `http.request` (success flag) |
| `http.slow_request` | HTTP > 2000ms (barrel:310) | http.* + `performance.category=slow` | ⚠️ fold into `http.request` |
| `network.monitor_initialized` | net monitor init (net_mon:46) | `initial_network_type`, monitor type | (internal; drop) |
| `network.connectivity_change` | net type change (net_mon:109) | `network.previous_type/current_type/available/change_direction` | ⚠️ → `network_change` |
| `performance.monitor_initialized` | perf monitor init (perf_mon:46) | monitor type, feature flags | (internal; drop) |
| `performance.app_startup` | after first frame (perf_mon:71) | `startup.duration_ms/type/first_frame` | ⚠️ → `page_load` (cold-start analogue) |
| `performance.frame_drop` | frame > 16.67ms (perf_mon:112) | `frame.build/raster/total_duration_ms`, `severity` | ⚠️ → `long_task` metric / `frame_render_time` |
| `performance.memory_pressure` | mem > 150/300/500MB (perf_mon:218) | `memory.usage_mb/pressure_level` | ⚠️ → `memory_usage` metric |
| `performance.system_check` | periodic 30s timer (perf_mon:150) | platform, rss, processor_count | (internal; drop or metric) |
| `navigation.route_change` | screen push/pop/replace (nav_obs:175) | `navigation.to/from/method`, `route.type/has_arguments` | ⚠️ → `navigation` |
| `user.profile_updated` | `setUserProfile()`/`clearUserProfile()` (barrel:641) | `user.id/profile_version`, name/email/phone | ⚠️ → `user.profile.update` |
| `user.profile_set` | `setUserProfile()` (barrel:644) | `user.has_*`, custom_attributes_count | ⚠️ fold into `user.profile.update` |
| `user.profile_cleared` | `clearUserProfile()` (barrel:707) | `profile_version` | ⚠️ fold into `user.profile.update` |

**Missing entirely vs canon:** `session.started`, `session.finalized`, `app_lifecycle`, `screen.duration` (emitted as a *metric* today), `user.interaction` (no tap capture), `custom_event` (host `trackEvent` uses arbitrary names, no `custom_event` wrapper), `app.crash` (errors go out as `type:error`, see §3).

## 2. Metrics emitted (6)

Metric `metricName` + `value` sit at item root (matches canon shape). Names diverge.

| Current metricName | Trigger | Value | Align to |
|---|---|---|---|
| `http.response_time` | every HTTP (barrel:288) | ms | (fold into `http.request` event `duration_ms`?) |
| `performance.startup_time` | first frame (perf_mon:78) | ms | ⚠️ → `page_load` |
| `performance.frame_time` | every frame (perf_mon:99) | ms (build+raster) | ⚠️ → `frame_render_time` |
| `performance.memory_usage` | 10s timer (perf_mon:127) | bytes (rss) | ⚠️ → `memory_usage` |
| `network.quality_score` | on net change (net_mon:137) | 0.0–5.0 | (no canon equivalent; decide) |
| `performance.screen_duration` | screen exit (nav_obs:131) | ms | ⚠️ → `screen.duration` (as **event** in canon) |

Canon metrics not present: `long_task`, `resource_timing`.

## 3. Errors / crashes

- Three entry points → all funnel to `trackError()` → `JsonEventTracker._sendCrashWithRetry()`:
  - `FlutterError.onError` (barrel:156)
  - `PlatformDispatcher.instance.onError` (barrel:161)
  - host-called `EdgeTelemetry.trackError()` (barrel:985)
- Sent **immediately, bypassing the batch queue**. On failure → `CrashStorage` (offline files) → `CrashRetryManager` periodic retry.
- Each crash gets a **fingerprint** (`ErrorType_msgHash_stackHash`) and carries **breadcrumbs** (ring buffer, cap **50** per audit — reference doc §5 canon is 20; reconcile in #4/#9).
- ⚠️ Wire item is `type:"error"` — **not** an `app.crash` event with a `cause` discriminator. Major divergence (see #4).

## 4. Wire payloads (from `JsonEventTracker` + `JsonHttpClient`)

**Event item** (tracker:61):
```json
{ "type": "event", "eventName": "http.request", "timestamp": "<ISO8601.SSSZ>", "attributes": { ...flat, all string... } }
```
**Metric item** (tracker:75): `{ "type": "metric", "metricName": "...", "value": <num>, "timestamp": "...", "attributes": {...} }`
**Error item** (tracker, immediate): `{ "type": "error", "error": "...", "timestamp": "...", "stackTrace": "...", "fingerprint": "...", "breadcrumbs": "<json string>", "attributes": {...} }`
**Batch envelope** (tracker:177):
```json
{ "type": "batch", "events": [ ... ], "batch_size": 30, "timestamp": "<ISO8601>" }
```

Divergences vs canon (reference doc §1):
- ❌ envelope `type` is **`"batch"`** — canon requires **`"telemetry_batch"`**.
- ❌ no batch-level `location` field.
- ✅ timestamps are ISO-8601 strings (`toIso8601String()`), not Unix ms — matches canon.
- ✅ attributes flat, primitives-as-strings — matches canon.
- ✅ metricName/value at root — matches canon.
- ❌ **transport**: `POST` to the raw `endpoint` URI as given; `Content-Type: application/json`; **no auth header set** (canon requires `X-API-Key: edge_*` and path `<endpoint>/collector/telemetry`). (jsonhttp:12)
- ⚠️ batch triggers at 30 events **or 5-minute** timer (`_resetTimeoutTimer()` hardcodes ~5min); config `batchTimeout` default is 5s and applies to the **OTel** path only — the JSON timeout is not config-driven. Canon flush ~5s.

## 5. Public API surface (`EdgeTelemetry` singleton, ~40 members)

- **Init/lifecycle:** `initialize({...16 params...})`, `instance`, `dispose()`, `isInitialized`, `config`.
- **Tracking:** `trackEvent(name, {attributes})`, `trackMetric(name, value, {attributes})`, `trackError(error, {stackTrace, attributes})`. Attributes are `dynamic` → coerced via `_convertToStringMap` (Map, `toJson()`, or reflected object).
- **Spans (OTel-only, no-op in JSON mode):** `withSpan`, `withNetworkSpan`, `startSpan`, `endSpan`. ⚠️ **Public API leaks OTel vocabulary** (`Span` type, span verbs) — violates the family terminology firewall (see #7 fog / #8).
- **User profile:** `setUserProfile({name,email,phone,customAttributes})`, `clearUserProfile()`, `currentUserId`, `currentUserProfile`. Versioned + persisted.
- **Breadcrumbs (9 methods):** `addBreadcrumb` + 6 typed helpers (navigation/userAction/system/network/ui/custom), `getBreadcrumbs()`, `clearBreadcrumbs()`.
- **Session/network/device:** `currentSessionInfo`, `getCurrentSession()`, `globalAttributes`, `currentNetworkType`, `getConnectivityInfo()`.
- **Local reporting (opt-in):** `generateSummaryReport`, `generatePerformanceReport`, `generateUserBehaviorReport`, `exportReportToFile`, `isLocalReportingEnabled`.
- **Navigation:** `navigationObserver` (wired into `MaterialApp`).

### Config fields (`TelemetryConfig`, 17)
`serviceName`*, `endpoint`*, `debugMode`(false), `globalAttributes`({}), `batchTimeout`(5s, OTel only), `maxBatchSize`(512, OTel spans), `enableNetworkMonitoring`(true), `enablePerformanceMonitoring`(true), `enableErrorReporting`(true), `enableNavigationTracking`(true), `enableHttpMonitoring`(true), `enableCrashReporting`(true), `enableLocalReporting`(false), `reportStoragePath`(null), `dataRetentionPeriod`(30d), `useJsonFormat`(true), `eventBatchSize`(30).
❌ vs canon config (reference doc §7): no `apiKey`, no `sampleRate`/sampling, no `ignoreUrls`, no `sanitizeUrl`, no `location`/`resolveLocation`, no app-identity split (`appName/appVersion/appPackage/appBuild/environment`) — only `serviceName`.

## 6. God-object concern map (barrel, ~1251 lines → 13 concerns)

Candidate service extractions (Android playbook §6 target = facade + 5 services):

| Concern | ~lines | Extract to |
|---|---|---|
| Initialization & setup (`_setup`, `_setupJson/Telemetry`, managers, monitoring wiring, crash handler install) | ~250 | facade wiring |
| User profile (set/clear/apply/version/persist) | ~150 | **UserProfile service** |
| Event/metric/error tracking + attribute coercion + fingerprint | ~130 | **EventTracking service** + **CrashReporting** |
| Breadcrumbs (9 methods) | ~70 | BreadcrumbManager (exists) |
| Span lifecycle (OTel) | ~50 | drop/hide (see #8) |
| HTTP monitoring (`_setupHttpMonitoring`, `_trackHttpRequest`) | ~50 | HTTP capture hook |
| Utilities (id gen, validation, state checks) | ~40 | private helpers |
| Report generation | ~40 | ReportGenerator (exists) |
| Attribute enrichment (`_getEnrichedAttributes`) | ~15 | **Collector/context-merge** |
| Session / network / perf / device / cleanup | ~40 | delegate to existing managers |

Existing managers already split out: `SessionManager`, `BreadcrumbManager`, `SpanManager`, `DeviceIdManager`, `UserIdManager`, `UserProfileManager`, `CrashRetryManager`, collectors/monitors. Gap vs canon architecture (§5): no single **Collector gatekeeper**, no **Pipeline/BatchProcessing** seam (batching lives inside `JsonEventTracker`), no **OfflineQueue** for normal events (only crashes persist).

## 7. Dual JSON / OTel backends

`_setup()` branches on `useJsonFormat`:
- **JSON (default, true):** `_setupJsonTelemetry()` → `JsonHttpClient(endpoint)` + `JsonEventTracker` (batch size, enrichment callback). `_spanManager` stays null. `_initializeManagers()` skipped.
- **OTel (false):** `_setupTelemetry()` → `BatchSpanProcessor(CollectorExporter(endpoint))` → `TracerProviderBase` → global registration → `SpanManager` → `EventTrackerImpl`.
- Both funnel through the `EventTracker` interface, so most call sites are format-agnostic.
- **No-op in JSON mode:** `withSpan` (runs op directly), `startSpan`→null, `endSpan`, `_applyUserProfile` (no spanManager), navigation/network span updates.
- **OTel dep:** `opentelemetry: ^0.18.10` (`pubspec.yaml:14`) — the only family SDK still shipping a real OTLP export path on the wire (reference doc §4). Removal mechanics = ticket #8.

## Open reconciliation items surfaced by the audit
1. **Breadcrumb cap 50 (code) vs 20 (canon §5)** → decide in #4/#9.
2. **ID formats**: audit observed `device_<13-ts>_<8char>_<platform>` / `user_<ts>_<8char>` vs canon `_{16hex}_` — confirm actual entropy width in **#6**.
3. **JSON batch timeout hardcoded ~5min, not config-driven** (config `batchTimeout` is OTel-only) → offline-queue/reliability design **#9**.
