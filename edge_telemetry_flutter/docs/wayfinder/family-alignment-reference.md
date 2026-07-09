# Edge RUM SDK Family — Alignment Reference (Flutter)

> Synthesis of the sibling SDKs (iOS, React Native, Ionic/Angular/Capacitor, Android) +
> the June-2026 "Data Capture Reference — EdgeRum" doc. This is the target the Flutter
> SDK aligns to. Captured during wayfinder charting; source for the map's research tickets.

## 1. The canonical wire contract (family-converged)

iOS, React Native, and the current Ionic code all emit **identical** envelope + eventNames.
The June-2026 reference doc matches them. **Android v2 and current Flutter are the laggards.**

**Batch envelope:**
```json
{ "type": "telemetry_batch", "timestamp": "ISO8601.SSSZ", "location": "Nairobi/Kenya",
  "batch_size": 3, "events": [ ... ] }
```
- Outer `type` = `"telemetry_batch"` (NOT `"batch"` — current Flutter + Android v2 send `"batch"`).
- `timestamp`: ISO-8601 string with `.SSS` fractional seconds, never Unix ms.
- `location` optional (batch-level).

**Event / metric item:**
```json
{ "type": "event",  "eventName":  "navigation",        "timestamp": "...", "attributes": {..flat..} }
{ "type": "metric", "metricName": "frame_render_time", "value": 18.4, "timestamp": "...", "attributes": {..} }
```
- `attributes` FLAT, primitives only (string | number | bool). No nesting, no arrays-of-objects.
- Every event carries full identity context merged in (app.*, device.*, network.*, session.*, user.*, sdk.*).
- Metric `metricName` + `value` at ROOT, not inside attributes.

**Transport:** `POST <endpoint>/collector/telemetry`, header `X-API-Key: edge_*` (never `Authorization`),
`Content-Type: application/json`. Retry schedule `[0, 2s, 8s, 30s]`, retry on status `0 / 429 (Retry-After) / 503`,
discard non-retryable 4xx. Offline queue FIFO, cap ~200, drains on reconnect + foreground + opportunistically.

## 2. Event allowlist (the alignment target)

| eventName | Trigger | Flutter today |
|---|---|---|
| `session.started` | init / resume after 30-min idle / rotation | ❌ missing |
| `session.finalized` | background / app close (immediate flush; journey summary) | ❌ missing |
| `app_lifecycle` | foreground / background transition | ❌ missing |
| `page_load` | initial document/app load timing | ❌ missing (mobile analogue = cold start) |
| `navigation` | screen-to-screen (from→to, method, route_type) | ⚠️ has NavigationObserver, wrong name |
| `screen.duration` | screen exit dwell (`screen.duration_ms`) | ❌ missing |
| `http.request` | HTTP capture (url, method, status, duration, success) | ✅ name matches |
| `user.interaction` | tap/click | ❌ missing |
| `network_change` | connectivity change | ⚠️ emits `network.connectivity_change` |
| `user.profile.update` | `identify()` | ⚠️ emits `user.profile_*` |
| `custom_event` | host `track(name)` → name in `event.name` attr | ⚠️ emits `custom.event` |
| `app.crash` | ALL errors funnel here w/ `cause` discriminator + `crash.breadcrumbs` | ⚠️ emits `type:error` immediate, not `app.crash` event |

**Metrics:** `frame_render_time`, `memory_usage`, `long_task`, `resource_timing`, custom (via `time()`).
Web-only (N/A on Flutter mobile): `LCP FCP CLS INP TTFB`. Flutter today emits `performance.frame_drop` /
`performance.frame_time` / `performance.memory_pressure` — need remap to `frame_render_time` / `memory_usage` metrics.

**`app.crash` cause discriminator** (all error kinds funnel into one eventName):
`Error` / `ConsoleError` / `ConsoleWarn` / `AngularError` (web) / `NativeCrash` / `Hang` (iOS) / `ANR` (Android).
Flutter analogues: `FlutterError`, `PlatformDispatcher.onError`, zone errors, isolate errors.

## 3. ID formats (persisted, not rotated)
```
device.id:  device_{epochMs}_{16hex}_{platform}   (persisted; platform = ios|android|web)
session.id: session_{epochMs}_{16hex}_{platform}  (fresh per session; 30-min idle → new)
user.id:    user_{epochMs}_{16hex}                (SDK-owned anon; identify() does NOT change it)
```
16 hex = 64-bit entropy. `sdk.platform` value for Flutter TBD (e.g. `flutter` — backend must accommodate).

## 4. OpenTelemetry status across the family — IMPORTANT
- **iOS**: keeps `opentelemetry-swift-core` 2.x ONLY as an internal, `@_implementationOnly` bridge that converts
  finished spans → `recordEvent()`. Zero OTel on the wire. Zero OTel vocabulary in public API.
- **React Native**: no OTel at all. Custom JSON only.
- **Ionic**: bundles `@opentelemetry/*` internally (never peer/exported) but sends custom JSON, NOT OTLP/protobuf.
  No `traceId`/`spanId`/`resourceSpans` on the wire.
- **Android v2**: no OTel dependency; custom JSON. (v3 plan flirts with OTel-native but not shipped.)
- **Current Flutter**: `opentelemetry: ^0.18.10`, genuine dual-mode — JSON mode (default) + a real OTel
  `CollectorExporter` mode. **This is the only SDK still shipping a real OTel export path on the wire.**

→ Family direction is **custom-JSON-only, OTel hidden or dropped**. "Pick latest OpenTelemetry" needs a
decision: follow family (drop/hide OTel-on-wire) vs keep a genuine OTLP export path. See map ticket.

## 5. Converged code-health architecture (all siblings)
```
Public facade (EdgeRum)            ← product vocabulary only; terminology firewall
  → Collector / EventTracking       ← single gatekeeper: sampling gate, context merge, breadcrumb, counters
    → Pipeline / BatchProcessing    ← buffer, batch (size/timer), immediate path for crash/session
      → RetryTransport / HttpClient ← POST, backoff, X-API-Key
        → OfflineQueue              ← FIFO persistence, drain-on-reconnect
Managers: SessionManager, ContextManager, UserProfileManager, BreadcrumbManager (ring, cap 20)
Capture hooks return dispose handles; DI via constructor/callbacks; test seams (__getCollector etc.)
Errors in capture swallowed → internal health monitor, never thrown to host app.
```

## 6. Android's proven refactor playbook (the template for this effort)
Android went god-object → clean via 4 phases (all backward-compatible, zero public API breaks):
1. **Quick wins**: fix resource/connection leaks, remove duplicate crash handlers, delete dead code (~300 lines, 17%).
2. **Service extraction**: god-object (1400 lines) → facade + 5 services (EventTracking, Session, UserProfile,
   CrashReporting, BatchProcessing). ~28% reduction, SOLID.
3. **Testing**: 200+ tests, 90%+ coverage, perf benchmarks (<1ms event record).
4. **Validation & backend alignment**: EventPayloadValidator / RuntimeEventValidator / AttributeValidator;
   75+ cases; align eventNames + required attributes to backend.

Current Flutter parallels Android's *starting* state: 1251-line god-object in the barrel file
(`lib/edge_telemetry_flutter.dart`), dual JSON/OTel backends, divergent eventNames.

## 7. Config API (family-common shape, adapt to Dart)
Required: `apiKey` (must start `edge_`), `endpoint`. App identity: `appName/appVersion/appPackage/appBuild/environment`.
Batch: `location`, `resolveLocation`. Sampling: `sampleRate` (per-session), `ignoreUrls`. Transport: `flushIntervalMs`
(~5s), `batchSize` (~30), `maxQueueSize` (~200). Capture toggles per signal. `sanitizeUrl`, `debug`.

## Source repos (cloned to scratchpad during charting)
- iOS: `NCG-Africa/edge_telemetry_ios_sdk` — gold-standard architecture, formal ADR log (`docs/decisions.md`), strict `Recorder.allowedEventNames`.
- React Native: `NCG-Africa/edge_telemetry_react_native` — allowlist identical to iOS.
- Ionic: `NCG-Africa/edge_telemetry_ionic_angular_capacitor` — most complete; `docs/terminology.md` firewall (note: eventName table in it is STALE; code is canonical).
- Android: `NCG-Africa/edge_telemetry_android` (local) — the 4-phase refactor playbook, PHASE_*_*.md reports.
