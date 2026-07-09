# Target Module Architecture — Flutter v2 (de-god-object the barrel)

> Resolves ticket [#7](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/7) (grilling, HITL — decided with the dev 2026-07-09).
> The structural half of the v2 refactor spec: the target Dart module layout that replaces the
> 1251-line god-object in `lib/edge_telemetry_flutter.dart`, mirroring the family layering.
> Companion to [`family-alignment-reference.md`](./family-alignment-reference.md) §5 (the canon this mirrors),
> [`before-inventory.md`](./before-inventory.md) §6 (the god-object concern map this dismantles),
> [`eventname-envelope-mapping.md`](./eventname-envelope-mapping.md) + [`id-identity-contract.md`](./id-identity-contract.md) (the data half).
> Assumes **OTel is dropped from the wire** (single custom-JSON backend). Removal *mechanics* = ticket #8; this doc draws the post-removal shape.
> **Planning artifact — no code.** The tree + responsibilities + seams; the executor builds from it.

## 1. Layer model — full 5-layer family split

The target mirrors the family canon (reference §5) **1:1** — chosen over a pragmatic subset because v2 is prod-grade and cross-SDK parity lets an iOS/Android reviewer read it instantly.

```
EdgeTelemetry (facade)          ← product vocabulary only; ~40 members; delegation + wiring graph; shutdown()
  → Collector                    ← per-event gatekeeper: sample gate · context merge · breadcrumb attach · counters
    → Pipeline                   ← buffer; enqueue() batched (size 30 / 5-min timer); sendNow() immediate path
      → RetryTransport           ← POST + exponential backoff + X-API-Key
        → OfflineQueue           ← FIFO persistence; drain-on-reconnect

Managers (beside the stack):  SessionManager · ContextManager · UserProfileManager · BreadcrumbManager
                              DeviceIdManager · UserIdManager
Capture hooks (feed Collector via EventSink):  Http · Nav · Lifecycle · Perf   (each returns a dispose handle)
Crash:  CrashReporting  (fingerprint + cause discriminator → Collector.sendNow)
```

Errors thrown *inside* capture/collection are swallowed to an internal path, never rethrown to the host app (family invariant).

## 2. Target file tree

```
lib/edge_telemetry_flutter.dart        ← barrel: EXPORTS ONLY (facade + public models). No logic.
lib/src/
  facade/
    edge_telemetry.dart                ← thin singleton; ~40 public members delegate; owns _TelemetryWiring; shutdown()
  core/
    edge_event.dart                    ← internal event model: eventName, attrs, priority (batched | immediate)
    collector.dart                     ← gatekeeper (see §3.1)
    pipeline.dart                      ← buffer + batch/immediate (see §3.2)
    retry_transport.dart               ← POST + backoff + X-API-Key   (absorbs old http/)
    offline_queue.dart                 ← FIFO persist + drain          (absorbs old storage/crash_storage.dart)
  managers/
    session_manager.dart               ← session lifecycle + counters + per-session sample roll
    context_manager.dart               ← NEW: global context state + snapshot()  (see §3.3)
    user_profile_manager.dart
    breadcrumb_manager.dart
    device_id_manager.dart
    user_id_manager.dart
  capture/
    capture_hook.dart                  ← CaptureHook interface + EventSink seam
    http_capture_hook.dart             ← wraps HttpOverrides; dispose restores prior global
    nav_capture_hook.dart              ← EdgeNavigationObserver (consumer-placed; sink injected)
    lifecycle_capture_hook.dart        ← WidgetsBindingObserver → app_lifecycle
    perf_capture_hook.dart             ← frame/memory → frame_render_time / memory_usage
  crash/
    crash_reporting.dart               ← fingerprint (ErrorType_msgHash_stackHash) + cause discriminator
  collectors/
    flutter_device_info_collector.dart ← unchanged
  config/
    telemetry_config.dart              ← + sessionSampleRate (default 1.0)
  reports/                             ← existing opt-in local reporting, untouched
```

**Deleted in the refactor** (each justified by a merge above it):

| Deleted | Absorbed by |
|---|---|
| `http/json_http_client.dart`, `http/telemetry_http_overrides.dart` | `core/retry_transport.dart` + `capture/http_capture_hook.dart` |
| `storage/crash_storage.dart` | `core/offline_queue.dart` (unified persistence) |
| `managers/crash_retry_manager.dart` | `core/retry_transport.dart` (unified backoff) |
| `monitors/flutter_network_monitor.dart`, `monitors/flutter_performance_monitor.dart` | `capture/` hooks + ContextManager (`network.type`) |
| `managers/json_event_tracker.dart` | split into `collector` + `pipeline` + `retry_transport` |
| `managers/span_manager.dart`, `managers/event_tracker_impl.dart` | dropped (no OTel wire — ticket #8) |
| `core/interfaces/event_tracker.dart` | dropped (no dual backend → no interface for two impls) |
| `telemetry/edge_telemetry.dart` | already-dead file — removed |

## 3. Per-component responsibilities

### 3.1 Collector — the single gatekeeper
Holds **no** state. For each `EdgeEvent` from a capture hook / API call:
1. **Sample gate** — `if (!_shouldSample(event)) drop`. Policy: per-session (§3.4). `event.priority == immediate` (crash, `session.started`, `session.finalized`) **always passes**.
2. **Context merge** — fold `ContextManager.snapshot()` into the event's attributes.
3. **Breadcrumb attach** — for error/crash events, attach `BreadcrumbManager` ring (event-scoped, *not* in the global snapshot).
4. **Counters** — bump session event/error counters (delegates to SessionManager).
5. **Route** — `event.priority == batched` → `Pipeline.enqueue`; `immediate` → `Pipeline.sendNow`.

`_getEnrichedAttributes()` (old barrel method) **dies here**: its state half → ContextManager, its merge half → step 2 (one line).

### 3.2 Pipeline — buffer + dispatch
Two entry points, one transport:
- `enqueue(event)` — append to buffer; flush the batch when it hits **size 30** or the **5-min timer** fires (both carried over from `JsonEventTracker`, now config).
- `sendNow(event)` — assemble a one-event `telemetry_batch` and hand straight to `RetryTransport` (crash/session bookends — never wait for a batch).

Both paths build the same `{ type: "telemetry_batch", timestamp, batch_size, events }` envelope and call the **same** `RetryTransport`. Pipeline is transport- and crash-agnostic.

### 3.3 ContextManager — global context state (NEW)
Single source of truth for the mutable global bag: `device.*`, `app.*`, `user.id`, current `session.*`, `network.type`, and the `session.sampled` flag. Mutated by SessionManager (session attrs, sampled flag), the network capture hook (`network.type`), UserProfileManager/UserIdManager (`user.*`). Exposes `Map<String,String> snapshot()` — the enriched set at this instant. **This is the testable replacement for the barrel's `_getEnrichedAttributes` state.**

### 3.4 Sampling — per-session, coherent
`sessionSampleRate` (0.0–1.0, **default 1.0** = 100%, zero behavior change). At session start `SessionManager` rolls **once**; result stored as `session.sampled` in ContextManager. Collector's sample gate reads it. A sampled-out session drops **all** its batched events (coherent journeys — you see the whole session or none), but crashes + `session.started`/`session.finalized` always send. Per-event sampling was rejected (shreds session/funnel analytics).

### 3.5 Crash path — unified rail
`CrashReporting` computes the fingerprint + `cause` discriminator (Dart errors `cause=Error` non-fatal; native `NativeCrash`/`ANR`/`Hang` fatal — see mapping doc §crash), builds the `app.crash` event at `immediate` priority, hands to `Collector.sendNow`. From there it rides the **same** `RetryTransport → OfflineQueue` as everything else — on network failure it persists to the single FIFO queue and drains on reconnect. The old parallel `CrashStorage` + `CrashRetryManager` rail is **gone**; two backoff/persistence systems collapse to one.
> Crash-specific *policy* (retry caps, fingerprint-level dedup in the queue, priority ordering) is refined by **#9** (reliability) and **#10** (native crash). #7 draws the single rail; they tune it.

### 3.6 Capture hooks — uniform seam + lifecycle
```dart
abstract class CaptureHook { Disposable start(EventSink sink); }
abstract class EventSink   { void add(EdgeEvent event); }   // implemented by Collector
```
Four impls feed the same sink:
- `HttpCaptureHook` — wraps `HttpOverrides.installGlobal`; **dispose restores the prior global** (no leak across hot-restarts). Emits the folded single `http.request`.
- `NavCaptureHook` — the `EdgeNavigationObserver`; the one **consumer-placed** hook (Flutter requires a `NavigatorObserver` in `MaterialApp`), but the Collector is injected as its sink.
- `LifecycleCaptureHook` — `WidgetsBindingObserver` → `app_lifecycle`.
- `PerfCaptureHook` — frame/memory → `frame_render_time` / `memory_usage`.

`EdgeTelemetry.shutdown()` (**additive** — no compat break) disposes every handle and flushes the Pipeline.

### 3.7 Facade — thin singleton over a DI'd core
`EdgeTelemetry` stays the **singleton** entrypoint (all ~40 members preserved → zero consumer migration; no second instance — YAGNI). It owns a private `_TelemetryWiring` builder that constructs the graph bottom-up: `OfflineQueue → RetryTransport → Pipeline → Collector`, injects the managers, starts the capture hooks, returns the handle bundle. Every public member is **delegation only**. OTel-era span methods become deprecated no-ops (mechanics → #8).

## 4. Test seams (the point of the split)

| Seam | How it makes something testable |
|---|---|
| `@visibleForTesting EdgeTelemetry.fromWiring(_TelemetryWiring)` | Inject a fully-faked stack; assert facade delegation without real init. |
| `EventSink` injected into every `CaptureHook` | Construct a hook with a **fake sink**, drive it, assert the exact `EdgeEvent`s — no globals, no real HTTP. |
| `ContextManager.snapshot()` | Direct assertion on the enriched attribute set (was the untestable `_getEnrichedAttributes`). |
| `RetryTransport` injected into `Pipeline` | Fake transport → assert batch envelope shape, flush triggers (size 30 / timer), immediate vs batched routing. |
| `Collector._shouldSample` + `session.sampled` | Force sampled-out → assert batched events dropped, crash/bookends still sent. |
| `OfflineQueue` injected into `RetryTransport` | Fake network failure → assert persist; fake reconnect → assert drain order (FIFO). |

One construction site (`_TelemetryWiring`), one injection point (`fromWiring`) — mirrors the iOS `__getCollector()` seam, Dart-flavored.

## 5. What this doc does NOT decide (handed to other tickets)
- **OTel removal mechanics** (delete vs hidden-bridge; span-method deprecation) → **#8**.
- **Reliability policy** on the unified rail (retry caps, OfflineQueue-for-normal-events semantics, dedup, backoff curve) → **#9**.
- **Native crash capture** mechanics feeding `CrashReporting` → **#10**.
- **Refactor phasing** (which classes land in which phase) → map fog *Refactor phasing plan*; this tree is its primary input.
- **Terminology firewall** for the public surface → map fog *Terminology firewall*.
