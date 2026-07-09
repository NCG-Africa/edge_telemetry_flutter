# edge_telemetry_flutter v2.0.0 — Refactor Spec & Data Glossary

> **The destination artifact.** Assembles the reviewed decisions from wayfinder map
> [#1](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/1) (tickets #2–#13) into one
> hand-off spec an implementer and the backend team execute + review from. This doc **collates**;
> each section gists a decision and links the authoritative detail doc — no decision is re-litigated here.
> Resolves [#14](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/14).

## 0. Overview

**What v2 is:** align `edge_telemetry_flutter` to the Edge RUM SDK family — custom-JSON `telemetry_batch`
wire + the shared eventName allowlist — **drop OpenTelemetry from the wire**, add full native crash capture,
and de-god-object the 1251-line barrel into the family's 5-layer architecture. Mobile only (iOS + Android).

**Version posture:** the **wire breaks at v2.0.0** (allowed); the **public Dart API stays backward-compatible**
(deprecate, don't remove — with 4 pre-announced/OTel hard-removes as the sanctioned exception). Split release:
a small backward-compat **v1.6** (quick-wins) precedes the **atomic v2.0.0**.

**Done =** this spec + glossary exist and are **reviewed, including by the backend team** (§10 is the review
packet). No code ships from this map; someone executes from §9's phased plan.

| Area | Section | Detail doc |
|---|---|---|
| Wire contract | §2 | [eventname-envelope-mapping](./eventname-envelope-mapping.md) |
| Data glossary (capture-more) | §3 | [extra-data-glossary](./extra-data-glossary.md) |
| Identity | §4 | [id-identity-contract](./id-identity-contract.md) |
| Reliability / session / sampling | §5 | [reliability-session-model](./reliability-session-model.md) |
| Native crash capture | §6 | [native-crash-capture](./native-crash-capture.md) |
| Module architecture | §7 | [target-module-architecture](./target-module-architecture.md) |
| OTel removal + API migration | §8 | [migration-deprecation-strategy](./migration-deprecation-strategy.md) |
| Terminology firewall | §8.4 | [terminology-firewall](./terminology-firewall.md) |
| Phased execution plan | §9 | [refactor-phasing-plan](./refactor-phasing-plan.md) |
| Backend asks (consolidated) | §10 | — |
| Ingestion contracts (grounding) | — | [collector-ingestion-contract](./collector-ingestion-contract.md), [backend-contract](./backend-contract.md) |
| Current state (before) | — | [before-inventory](./before-inventory.md) |

## 1. Starting point (before)

Today: a 1251-line god-object in the barrel `lib/edge_telemetry_flutter.dart`, dual JSON/OTel backends,
18 divergent events + 6 metrics. Key divergences from canon: envelope `type:"batch"` (not `telemetry_batch`),
**no `X-API-Key`** (the one thing that actually 401s today), errors as `type:"error"` items (no `app.crash`),
OTel vocabulary leaking into the public API. Full audit: [before-inventory](./before-inventory.md).

## 2. Wire contract (v2)

### 2.1 Batch envelope
```json
{ "type": "telemetry_batch", "timestamp": "<ISO8601.SSSZ>", "batch_size": 3, "events": [ ... ] }
```
- `type` → **`telemetry_batch`** (was `"batch"`). Free: neither Collector nor Processor branches on the value —
  only a non-empty string is required.
- SDK **never sends** `location`/`tenant_id`/`geo` — the Collector injects these from client IP + API key.
  Drop `location`/`resolveLocation` from config.
- `events` ≤ 1000 per batch (Collector cap).

### 2.2 Transport
`POST <endpoint>/collector/telemetry` · header **`X-API-Key: <key>`** · `Content-Type: application/json`.
Exact public path + key prefix + prod auth mode are **backend-team confirmations** (§10 Q1–Q3): the collector
app mounts `/telemetry` and expects a `prefix_keyid_secret` key; a gateway is presumed to rewrite `/collector/*`.

### 2.3 Event allowlist — 12 canon events
`✅` = dedicated backend table today · `⚠️` = lands in generic `rum_performance_events` fallback until the
backend adds a handler (accommodation request, §10). **All orphan events are emitted now** (no config gating).

| v2 eventName | from (v1) | backend |
|---|---|---|
| `session.started` | *new* | ✅ |
| `session.finalized` | *new* (carries journey summary, §5.3) | ✅ |
| `app_lifecycle` | *new* | ⚠️ |
| `page_load` | `performance.app_startup` + `performance.startup_time` | ⚠️ |
| `navigation` | `navigation.route_change` | ✅ |
| `screen.duration` | `performance.screen_duration` (**metric → event**) | ✅ |
| `http.request` | `http.request` **+ folds** `http.error`, `http.slow_request` | ✅ |
| `user.interaction` | *new* (tap/click) | ⚠️ |
| `network_change` | `network.connectivity_change` | ⚠️ |
| `user.profile.update` | folds `user.profile_updated/_set/_cleared` | ✅ |
| `custom_event` | host `trackEvent(name)` → `event.name = name` | ⚠️ |
| `app.crash` | `type:"error"` item | ✅ |

**Dropped from the wire** (internal noise): `telemetry.initialized`, `network.monitor_initialized`,
`performance.monitor_initialized`, `performance.system_check`.

### 2.4 `app.crash` — shape + cause taxonomy
Replaces the `type:"error"` item with an `app.crash` **event** (still immediate, bypasses the batch), keys
**unprefixed** (backend `rum_crash_events` extractors read them verbatim):
```json
{ "type": "event", "eventName": "app.crash", "timestamp": "...",
  "attributes": { "message": "...", "stacktrace": "...", "exception_type": "...",
                  "cause": "Error", "is_fatal": false, "crash.source": "flutter_error", ...identity... } }
```
Server computes `crash_hash`, `severity_level`, `breadcrumbs` — **client does not send these**.

| `cause` | source | `is_fatal` |
|---|---|---|
| `Error` | all Dart entry points (`FlutterError.onError`, `PlatformDispatcher.onError`, `runZonedGuarded`, isolate, host `trackError`) | `false` |
| `NativeCrash` | iOS signal/exception, Android JVM/NDK | `true` |
| `ANR` | Android app-not-responding | `true` |
| `Hang` | iOS main-thread hang | `true` |

Dart entry point is **not** in `cause` (all → `Error`); the specific handler goes in secondary `crash.source`.
Native capture mechanics → §6.

### 2.5 Metrics
Shape unchanged (`{type:"metric", metricName, value, timestamp, attributes}`).

| v2 metricName | from (v1) |
|---|---|
| `frame_render_time` | `performance.frame_time` (build/raster split in attrs, §3) |
| `memory_usage` | `performance.memory_usage` |
| `long_task` | `performance.frame_drop` (was an **event**) |
| `resource_timing` | *new (canon)* |

**Dropped:** `http.response_time` (→ `http.request.http.duration_ms`), `performance.startup_time` (→ `page_load`),
`network.quality_score` (no canon equivalent, no backend table).

### 2.6 Attribute-key style (deliberately mixed — matches processor extractors)
- **Dotted** — identity/domain: `app.* device.* session.* user.* sdk.* http.* navigation.* screen.* network.* page_load.* interaction.* lifecycle.*`
- **Dotless** — frame/memory metric internals: `build_time_ms`, `raster_time_ms`, `memory_type`, `memory_usage_mb`…
- **Unprefixed** — `app.crash` payload keys: `message`, `stacktrace`, `exception_type`, `cause`, `is_fatal`.

Do **not** force uniform dotting.

## 3. Data glossary — Flutter-unique "capture more" signals

All **additive**: flat primitives on an **existing** canon event/metric — no new eventName/metric/envelope.
Inclusion bar: *canon-can't* diagnose it **and** passive/cheap **and** zero-PII. Detail + rejected candidates:
[extra-data-glossary](./extra-data-glossary.md).

| On event/metric | Added keys |
|---|---|
| `frame_render_time` | `build_time_ms`, `raster_time_ms` (UI-build vs GPU-raster split — the whole jank-triage decision) |
| `app.crash` | `source` ∈ `flutter_error`/`platform_dispatcher`/`zone`/`isolate` (needs isolate error-listener wired) |
| `navigation` (+`screen.duration`) | `route.type` (e.g. `DialogRoute`), `route.has_arguments` (bool — **never** the values) |
| `page_load` | `startup.type` (cold/warm), `startup.time_to_first_frame_ms` (SDK-init-relative; document the caveat) |
| `app_lifecycle` | `lifecycle.state` (raw `AppLifecycleState`: `resumed`/`inactive`/`paused`/`hidden`/`detached`) |
| device context (all events) | `device.platform_brightness`; ⚠️ `device.text_scale_factor`, `device.reduce_motion` |

⚠️ `text_scale_factor` + `reduce_motion` are **accessibility-sensitive** → require backend/privacy sign-off
before first-class storage **and** a config opt-out gating capture (§10).

## 4. Identity contract

```
device.id       = device_{epochMs}_{16hex}_{ios|android}   (flutter_secure_storage; cross-install on iOS)
session.id      = session_{epochMs}_{16hex}_{ios|android}  (fresh per session; 30-min idle → new)
user.id         = user_{epochMs}_{16hex}                   (anon, STABLE across identify())
device.platform = "ios" | "android"                        (real OS; device grouping key)
sdk.platform    = "flutter-ios" | "flutter-android"        (NEW dashboard values)
```
- `{platform}` token = **real OS** (`Platform.operatingSystem`), so a Flutter-iOS device.id is byte-shape-identical
  to native-iOS — cross-platform grouping works with zero backend change. "Built with Flutter" lives only in `sdk.platform`.
- `device.id` moves off `shared_preferences` → **`flutter_secure_storage`** (new dep): iOS Keychain survives
  uninstall (same id on reinstall); Android EncryptedSharedPreferences wiped on uninstall (new id). **Asymmetry accepted.**
- `user.id` is SDK-owned anonymous; `identify()` attaches profile (`user.*`) but **never changes the id** → anon +
  identified events stitch to one timeline.
- Entropy widens 8-alnum (~41 bit, non-crypto) → **16 hex (64 bit) via `Random.secure()`**. The **format validator
  must accept both widths during migration** so an in-place upgrade keeps its id.
- `device.id` must appear somewhere in every batch or the Collector **400s**.

## 5. Reliability, session & sampling

Built on #7's unified `Pipeline → RetryTransport → OfflineQueue` rail. Full policy:
[reliability-session-model](./reliability-session-model.md).

### 5.1 Offline queue
- **File-per-batch** under `getApplicationDocumentsDirectory()/edge_telemetry_queue/`, `<epochMs>_<seq>.json`.
  No new dep (`path_provider` already present; generalizes today's `CrashStorage`). Drain = list, sort lexical,
  POST each, delete on `2xx`.
- Persist the **assembled `telemetry_batch` verbatim** (one file = one POST; drain is dumb replay). Cap ~200 batches,
  **drop-oldest, crashes exempt** (ride the `crash_` filename prefix). **No on-device dedup** (backend groups by fingerprint).
- **Retry handoff:** `if (offline || status==0) queueNow() else runBackoff([0,2s,8s,30s])thenQueue()`. Non-retryable
  4xx discarded. Drain failures just stay queued for the next trigger.

### 5.2 Session model (lazy, no timer)
- Idle rotation is a **last-activity check** on the next event/resume (`now - lastActivityAt > 30min` → rotate).
  No `Timer.periodic` (backgrounded Flutter can't run timers reliably).
- **`paused` = flush + mark, NOT finalize.** On `paused`: flush the buffer, record background ts. On `resume`:
  >30min → finalize old (**backdated**) + start new; else continue. On **next launch** after a kill: a stale
  persisted `session.id` with no finalize → emit its backdated `session.finalized`, then start fresh.
- Requires persisting `session.id` + `lastActivityAt` (`shared_preferences`) for kill-recovery.

### 5.3 `session.finalized` journey summary (new attrs → §10)
`session.duration_ms`, `session.event_count`, `session.error_count`, `session.crash_count`, `session.screen_count`,
`session.http_request_count`, and `session.screen_journey` (ordered route path, **capped 20 hops**).

### 5.4 Sampling — two orthogonal axes
Send-priority (`immediate` vs `batched`) and sampling (`bypass` vs `subject-to-sample`) are **separate**:

| Event | Priority | Sampling |
|---|---|---|
| `app.crash`, `session.started`, `session.finalized` | immediate | bypass |
| `user.profile.update` | **batched** | **bypass** (identity mutations must always land, but aren't time-critical) |
| everything else | batched | subject-to-sample |

Rolled **once per session** (`sampleRate`, default 1.0) → stored as `session.sampled`; a sampled-out session drops
all `subject-to-sample` events (coherent journeys), bypass set always sends.

### 5.5 Breadcrumbs & config
- Ring buffer cap **20**, crash-scoped (attached to `app.crash` as `crash.breadcrumbs`, not in global snapshot).
  Auto: nav + http (sanitized path) + lifecycle. Manual: new `addBreadcrumb(message, {category, data})`. Frames/metrics not crumbed.
- **Config knobs:** `sampleRate` (1.0), `maxQueueSize` (200), `batchSize` (30), `flushIntervalMs` (**5000** — reconciled
  from the latent 5-**minute** hardcode; a 60× defect fix). Internal constants (not exposed): retry schedule, 30-min idle.

## 6. Native crash capture (iOS + Android)

Full native in v2.0.0 → 100% `cause` coverage. **OS diagnostic APIs only — zero hand-rolled signal
handlers/watchdogs.** Detail: [native-crash-capture](./native-crash-capture.md).

- **New plugin layer** (package is pure-Dart today): first `ios/` (Swift) + `android/` (Kotlin) units behind one
  `MethodChannel` `edge_telemetry/native_crash`. **Pull-only, one method** `drainNativeCrashes()` called once on init
  → returns new `app.crash` payloads → #5's immediate crash rail. (A crashing process can't call Dart; next-launch pull
  is the only workable model.)
- **iOS:** MetricKit (`MXCrashDiagnostic` → `NativeCrash`, `MXHangDiagnostic` → `Hang`). **Hard floor iOS 14**;
  fallback deleted, not written. MetricKit self-dedups.
- **Android:** JVM `UncaughtExceptionHandler` on **all** APIs (`NativeCrash`); `ApplicationExitInfo` on **API 30+**
  (`REASON_CRASH_NATIVE` → `NativeCrash`, `REASON_ANR` → `ANR`; ignore its `REASON_CRASH` — the JVM handler owns JVM
  crashes). **Pre-30 native/ANR = documented gap**, surfaced via `sdk.native_capture_tier` (`full`/`jvm_only`).
  Watermark (last-exit ts in `shared_preferences`) prevents re-reading OS records.
- **Symbolication server-side** (raw stacks sent). iOS 14 floor is a **consumer Podfile build-break** → migration guide (§8).

## 7. Target module architecture

Replaces the barrel god-object with the family's **5-layer split** (mirrors canon 1:1). Detail + file tree + test
seams: [target-module-architecture](./target-module-architecture.md).

```
EdgeTelemetry (facade)    ← product vocab only; ~40 members delegate; owns _TelemetryWiring; shutdown()
  → Collector             ← per-event gatekeeper: sample gate · context merge · breadcrumb attach · counters
    → Pipeline            ← buffer; enqueue() batched (size 30 / 5s); sendNow() immediate
      → RetryTransport    ← POST + backoff + X-API-Key   (absorbs old http/)
        → OfflineQueue    ← FIFO persist + drain          (absorbs old crash_storage)
Managers: Session · ContextManager(NEW) · UserProfile · Breadcrumb · DeviceId · UserId
Capture hooks (→ EventSink): Http · Nav · Lifecycle · Perf   (each returns a dispose handle)
Crash: CrashReporting (fingerprint + cause → Collector.sendNow)
```
- **`ContextManager.snapshot()`** replaces the untestable `_getEnrichedAttributes` (its state half).
- Facade stays the **singleton** (all ~40 members preserved → zero consumer migration); barrel = **exports only**.
- **Deleted:** `http/`, `monitors/`, `storage/crash_storage`, `managers/crash_retry_manager`, `json_event_tracker`,
  `span_manager`, `event_tracker_impl`, `core/interfaces/event_tracker`, dead `telemetry/edge_telemetry.dart`.
- Crash rail **unified** — the old parallel `CrashStorage`+`CrashRetryManager` collapse into the one rail.
- 6 test seams enumerated (`fromWiring`, injected `EventSink`, `ContextManager.snapshot`, injected `RetryTransport`,
  `_shouldSample`, injected `OfflineQueue`).

## 8. OTel removal + public-API migration

**Full removal, no bridge** — the default path already ships zero OTel; a bridge would round-trip our own spans.
Detail: [migration-deprecation-strategy](./migration-deprecation-strategy.md). Rule: *deprecate, don't remove* =
don't remove **without a shipped-and-elapsed cycle** — so pre-announced removals are honored.

### 8.1 Hard-break set (4 symbols — sanctioned, no shim)
`startSpan`, `endSpan`, `activeScreenSpans` (return/expose the deleted OTel `Span` type), `runAppCallback`
(deprecated since ≤1.5.2 with "removed in v2.0.0"). Plus `EdgeNavigationObserver`'s span ctor params
(`registerScreenSpan`/`onSpanStart`/`onSpanEnd`) — same OTel-leak rationale. The observer's **consumer contract**
(`navigationObserver` getter + `MaterialApp` placement) is **preserved**; internals → time-based event emission.

### 8.2 Deprecated no-ops (3 — kept, removed in v3)
`useJsonFormat:false` (warn once), `withSpan`, `withNetworkSpan` (run fn, emit nothing). Each: `@Deprecated('… removed
in v3.0.0')` + a **once-per-process debug-gated runtime print**. Everything else keeps its signature; #9/#10 additions
(`addBreadcrumb()`, `maxQueueSize`, `shutdown()`) are additive.

### 8.3 Migration guide (README + CHANGELOG `## [2.0.0]`)
Framing: **"The wire changed — your code mostly didn't."** TL;DR for the common case = bump version + bump iOS Podfile
to 14. Sections: breaking (4 removals + iOS 14 + wire), deprecations table, the **min-iOS-14 Podfile build-break**
(required by MetricKit), "what you get" (native crash, offline reliability, family wire), CHANGELOG split
Breaking/Deprecated/Added/Changed. Straight to v2 (no v1.x OTel bridge); no-ops drop in v3.0.0.

### 8.4 Terminology firewall
**Forward-looking rule, not a rename pass** — backward-compat wins on every existing symbol. Governs only
docs/marketing, **net-new** public symbols, and error text. Detail: [terminology-firewall](./terminology-firewall.md).
- Banned in new surface (family canon verbatim): `span`/`trace`/`tracing`, `instrumentation`, `telemetry`,
  `metric` (in names), `OTLP`/`OpenTelemetry`, `emit`, `sampling`, `collector`, `pipeline`, `batch`/`flush` (prose)…
- **Grandfathered:** `EdgeTelemetry` class, `trackMetric`, the 3 deprecated no-ops.
- New symbols pass — **use `sampleRate`, not `sessionSampleRate`** (`sampleRate`/`batchSize`/`flushIntervalMs` are the
  sanctioned config-key exceptions). Existing config keys `batchTimeout`/`eventBatchSize`/`maxBatchSize` should align
  to `flushIntervalMs`/`batchSize` in the config surface (deprecate-old-keys, not firewall violations).
- Enforcement = **doc convention only** (no lint/CI — YAGNI for a spec).

## 9. Phased execution plan

Split release: **v1.6 = Phase 1 only** (backward-compat), then **atomic v2.0.0 = Phases 2–5**. Tests **woven
per-phase**; Phase 5 = system-level gate. Full plan + acceptance criteria:
[refactor-phasing-plan](./refactor-phasing-plan.md).

| Phase | Scope | Exit criteria (headline) |
|---|---|---|
| **1 — Quick wins** (v1.6) | delete dead file, fix leaks, dead code | analyze clean · wire **byte-identical to v1.5.2** · public-API diff = ∅ |
| **2 — Extraction + OTel removal** | 5-layer split + `ContextManager`; delete OTel machinery+dep; apply the OTel public break; **publish `drainNativeCrashes()` contract** | public-API diff = exactly the break set · **wire still byte-identical** (pure restructure) · 6 seam tests green |
| **3 — Wire flip + reliability/session** | envelope→`telemetry_batch`, X-API-Key, allowlist, `app.crash`, glossary keys; queue/retry/session/sampling/breadcrumbs; flush 5s; config renames | **wire snapshot matches family-canon fixtures** · session/sampling/queue tests green |
| **4 — Native plugin + crash** | MetricKit + AEI/JVM behind one MethodChannel; **plugin develops in parallel** off P2 contract, **delivery/e2e ordered here** (needs P3 rail); iOS 14 floor | builds iOS+Android · drain verified **on device matrix** · e2e fatal `app.crash` · `sdk.native_capture_tier` emitted |
| **5 — Tests + validation gate** (ships v2.0.0) | integration, coverage/perf, validators, migration guide | **backend-team sign-off** on wire + §10 asks (**destination-defining gate** — no ship on eng-green alone) |

**Ordering:** ContextManager/Collector→queue · OTel-removal→firewall renames · native contract(P2)→plugin, native
delivery(P4)→after P3 rail · wire held constant through P2. **Risk:** Phase 1 the only independently-shippable slice;
2–5 atomic. Highest risk = P4 native (hedged by the parallel track). **Flagged contingency (reopens #10, not silent):**
native slip → wire-first v2.0.0 + native v2.1.0.

## 10. Backend-team review packet (consolidated asks)

Everything the SDK needs the backend/dashboards to confirm or accommodate. **The Collector is a content-agnostic
passthrough** (`extra="allow"`, strict validation off) so new data *reaches* Kafka freely; first-class storage/query
is gated at the **processor** and needs the accommodations below.

**A. Confirmations (block the wire being correct):**
1. **Ingest URL / path** — is `/collector/telemetry` gateway-rewritten to the collector's `/telemetry`? Confirm the
   exact URL per environment.
2. **API key** — the provisioned key string/prefix for the Flutter app (code shows `prefix_keyid_secret`, e.g.
   `edgekey_*`; reference said `edge_*`) and which tenant/app it maps to; who issues it.
3. **Auth mode in prod** — `api_key` (→ `X-API-Key`) or `jwt` (→ `Authorization: Bearer`)?
4. **`app.crash` shape** — confirm the processor still wants unprefixed keys (`message`/`stacktrace`/`cause`/
   `exception_type`/`is_fatal`) and computes `crash_hash`/`severity`/`breadcrumbs` server-side.
5. **Cross-install device.id (iOS)** — confirm no backend assumption that a reinstall yields a new device row; on
   Flutter-iOS the same `device.id` reappears post-reinstall.

**B. Accommodation requests (data lands in the fallback until handled):**
6. **New eventName handlers** for the orphans: `page_load`, `app_lifecycle`, `user.interaction`, `custom_event`,
   `network_change` (else they sit in `rum_performance_events`).
7. **`session.finalized` journey-summary** attributes (§5.3) — store for session/funnel analytics.
8. **Glossary keys** (§3) as passthrough columns: `build_time_ms`/`raster_time_ms` on `frame_render_time`; `source`
   on `app.crash`; `route.type`/`route.has_arguments` on `navigation`; `startup.type`/`startup.time_to_first_frame_ms`
   on `page_load`; `lifecycle.state` on `app_lifecycle`; `device.platform_brightness`.
9. **`sdk.platform` new values** `flutter-ios`/`flutter-android` — update any platform-filter dashboard UI (ingest
   already tolerant).
10. **`sdk.native_capture_tier`** (`full`/`jvm_only`) passthrough attr so per-device coverage gaps are visible.
11. **`cause` values** `NativeCrash`/`ANR`/`Hang` on `app.crash` — confirm tolerated.
12. **Server-side symbolication** for raw iOS `callStackTree` + Android tombstone/NDK stacks (dSYM/symbol-upload infra).

**C. Privacy sign-off (before first-class storage):**
13. **`device.text_scale_factor`** + **`device.reduce_motion`** — accessibility-sensitive; the SDK gates them behind a
    config opt-out, but they need backend/privacy review before first-class storage.
