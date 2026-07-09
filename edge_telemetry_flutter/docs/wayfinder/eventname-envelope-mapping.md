# EventName + Envelope Alignment Mapping (Flutter → family)

> Resolves ticket #4 (grilling, HITL — decided with the dev 2026-07-09).
> The wire-contract fragment of the v2 refactor spec: the exact Flutter→family
> eventName/attribute mapping + deprecations. Companion to
> [`family-alignment-reference.md`](./family-alignment-reference.md) (target),
> [`before-inventory.md`](./before-inventory.md) (current state),
> [`backend-contract.md`](./backend-contract.md) + [`collector-ingestion-contract.md`](./collector-ingestion-contract.md) (what the backend stores),
> [`id-identity-contract.md`](./id-identity-contract.md) (identity attrs).
> All wire changes are **v2.0.0 breaks** (allowed); the public Dart API stays backward-compatible.

## 1. Batch envelope

```json
{ "type": "telemetry_batch", "timestamp": "<ISO8601.SSSZ>", "batch_size": 3, "events": [ ... ] }
```

| field | v1 today | v2 | note |
|---|---|---|---|
| `type` | `"batch"` | **`"telemetry_batch"`** | Aligns to canon. Free — neither Collector nor Processor branches on the value (only requires a non-empty string). See collector-contract §4. |
| `timestamp` | ISO-8601 `.SSS` | unchanged | already correct |
| `batch_size` | present | unchanged | |
| `location` | absent | **still absent — SDK never sends it** | Collector injects `location`+`geo` from client IP. SDK MUST NOT send `location`/`tenant_id`/`geo`. Drop `location`/`resolveLocation` from config. |
| `events` | array | unchanged | Collector caps length ≤ 1000 |

**Transport (from identity/family docs, restated for completeness):** `POST <endpoint>/collector/telemetry`, header `X-API-Key: <key>` (never `Authorization` in api_key mode), `Content-Type: application/json`. Exact public path + key prefix are backend-team questions (collector-contract §6 Q1–Q3).

## 2. Event allowlist — v2 wire (12 canon events)

`✅ backend has a dedicated table` · `⚠️ lands in generic rum_performance_events fallback until backend adds a handler (accommodation request)`.
Decision: **emit all orphan events now** (no config gating); flag each fallback event as "needs backend accommodation" in the spec.

| v2 eventName | from (v1) | trigger | attributes (keys) | backend |
|---|---|---|---|---|
| `session.started` | *new* | init / resume after 30-min idle | identity ctx only (session auto-created server-side) | ✅ (detail → #9) |
| `session.finalized` | *new* | background / close (immediate flush; journey summary) | `session.duration_ms`, `session.start_time` + summary counts | ✅ (detail → #9) |
| `app_lifecycle` | *new* | foreground / background transition | `lifecycle.state` (`resumed`/`paused`/…) | ⚠️ |
| `page_load` | `performance.app_startup` (event) + `performance.startup_time` (metric) | after first frame (cold-start analogue) | `page_load.duration_ms`, `page_load.type` (cold/warm), `page_load.first_frame` | ⚠️ (kept — cold-start analogue) |
| `navigation` | `navigation.route_change` | screen push/pop/replace | `navigation.from_screen`, `navigation.to_screen`, `navigation.method`, `navigation.route_type`, `navigation.has_arguments` | ✅ |
| `screen.duration` | `performance.screen_duration` (**metric** → now **event**) | screen exit dwell | `screen.name`, `screen.duration_ms`, `screen.exit_method` | ✅ |
| `http.request` | `http.request` **+ folds in** `http.error`, `http.slow_request` | every HTTP completes | `http.url`, `http.method`, `http.status_code`, `http.duration_ms`, `http.success` (bool) | ✅ |
| `user.interaction` | *new* | tap / click | `interaction.type`, `interaction.target` (capture design → #5) | ⚠️ |
| `network_change` | `network.connectivity_change` | connectivity change | `network.previous_type`, `network.current_type`, `network.available`, `network.change_direction` | ⚠️ |
| `user.profile.update` | folds `user.profile_updated` + `user.profile_set` + `user.profile_cleared` | `identify()` / `setUserProfile()` / `clearUserProfile()` | `user.id`, `user.name`, `user.email`, `user.phone`, `user.profile_version`, `user.profile_updated_at` + arbitrary `user.*` | ✅ |
| `custom_event` | host `trackEvent(name)` (arbitrary names today) | host `track` | `event.name` = the host-supplied name; host attrs pass through | ⚠️ |
| `app.crash` | `type:"error"` item (immediate) | see §3 | see §3 | ✅ |

### Internal events DROPPED from the wire (were noise)
`telemetry.initialized`, `network.monitor_initialized`, `performance.monitor_initialized`, `performance.system_check`. Not emitted in v2.

## 3. `app.crash` — shape + cause taxonomy

**Shape change:** the immediate `type:"error"` item is replaced by an **`app.crash` event** (still sent immediately, bypassing the batch queue) with **unprefixed** keys (backend `rum_crash_events` extractors read these verbatim):

```json
{ "type": "event", "eventName": "app.crash", "timestamp": "...",
  "attributes": {
    "message": "...", "stacktrace": "...", "exception_type": "...",
    "cause": "Error", "is_fatal": false,
    "crash.source": "FlutterError.onError",   // secondary — entry-point detail
    ...identity ctx...
  } }
```
- Server computes `crash_hash`, `severity_level`, and stores `breadcrumbs` — **client does not send these** (breadcrumb ring-buffer cap 50→20 reconciliation + whether the client attaches breadcrumbs at all is a backend-team question, → #9 / collector-contract §6 Q5).
- Optional passthrough keys the backend also reads: `error_context`, `error_code`, `user_action`, `product_id`.

**`cause` vocabulary (Flutter):**

| cause | source | is_fatal | in v2? |
|---|---|---|---|
| `Error` | ALL Dart entry points — `FlutterError.onError`, `PlatformDispatcher.onError`, `runZonedGuarded`, isolate errors, host `trackError()` | `false` | ✅ yes |
| `NativeCrash` | iOS ObjC/Swift signal, Android JVM/NDK | `true` | ✅ yes (→ native-capture ticket) |
| `ANR` | Android app-not-responding | `true` | ✅ yes (Android only) |
| `Hang` | iOS main-thread hang | `true` | ✅ yes (iOS only) |

- Dart entry point is **not** encoded in `cause` (all → `Error`, family-aligned); the specific handler goes in the secondary `crash.source` attribute.
- **All Dart-caught errors are `is_fatal: false`** (the app survived — we caught it). Only native crashes are `is_fatal: true`.
- **Native crash capture is IN SCOPE for v2** but its mechanics (native signal/ANR/Hang handlers, platform-channel bridge, cross-launch offline persistence) are a distinct design — see the new native-crash-capture ticket.

## 4. Metrics remap

Metric shape unchanged (`{type:"metric", metricName, value, timestamp, attributes}`; `metricName`+`value` at root).

| v2 metricName | from (v1) | note |
|---|---|---|
| `frame_render_time` | `performance.frame_time` | every frame; UI(build)/raster split kept in attrs → #5 |
| `memory_usage` | `performance.memory_usage` | rss |
| `long_task` | `performance.frame_drop` (was an **event**) | slow frame (>16.67ms) → long-task metric |
| `resource_timing` | *new (canon)* | per-resource load timing (scope → #5) |
| — | ~~`http.response_time`~~ | **dropped** — folds into `http.request` event `http.duration_ms` |
| — | ~~`performance.startup_time`~~ | **dropped** — folds into `page_load` event |
| — | ~~`network.quality_score`~~ | **dropped** — no canon equivalent, no backend table |
| moved | `performance.screen_duration` | now the `screen.duration` **event** (§2) |

## 5. Attribute key style (resolves backend-conflict #2)

The wire is **deliberately mixed**, matching the processor's extractors — do NOT force uniform dotting:
- **Dotted** for identity + domain events: `app.*`, `device.*`, `session.*`, `user.*`, `sdk.*`, `http.*`, `navigation.*`, `screen.*`, `network.*`, `page_load.*`, `interaction.*`, `lifecycle.*`.
- **Dotless** for frame/memory metric internals: `frame_build_duration`, `frame_raster_duration`, `memory_type`, `memory_usage_mb`, etc. (processor prefers dotless here; dotted is legacy-compat).
- **Unprefixed** for `app.crash` payload keys (§3): `message`, `stacktrace`, `exception_type`, `cause`, `is_fatal`.

Per-attribute detail for the extra-data signals is #5's job; this fixes the *rule*.

## 6. Deprecations

Wire renames are internal to the SDK (the host doesn't choose eventNames), so no public-API break — but note:
- `trackEvent(name, ...)` now **wraps** into `custom_event` with `event.name = name` (behavior change, API-compatible).
- Config: `location`, `resolveLocation` dropped (never sent); `batchTimeout`/`maxBatchSize` (OTel-only today) revisited under #8/#9.
- Old wire names (`http.error`, `http.slow_request`, `navigation.route_change`, `user.profile_*`, `performance.*`, `network.connectivity_change`, `type:"error"` item) cease to exist on the wire in v2.
