# Reliability, Offline Queue & Session Model — Flutter v2

> Resolves ticket [#9](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/9) (grilling, HITL — decided with the dev 2026-07-09).
> The **policy** half of the unified rail that [`target-module-architecture.md`](./target-module-architecture.md) §3.5 draws structurally.
> #7 built the single `Pipeline → RetryTransport → OfflineQueue` rail; this doc tunes its behaviour: queue storage & semantics, retry handoff, the session lifecycle model, breadcrumbs, and the sampling-bypass contract.
> Companion to [`family-alignment-reference.md`](./family-alignment-reference.md) §2 (retry/queue canon), [`collector-ingestion-contract.md`](./collector-ingestion-contract.md) (`device.id` gate, `events`≤1000), [`eventname-envelope-mapping.md`](./eventname-envelope-mapping.md) (event vocabulary + `app.crash`).
> **Planning artifact — no code.** Decisions + rationale; the executor builds from it.

Values fixed by the family canon and *not* re-litigated here: retry schedule `[0, 2s, 8s, 30s]` on status `0/429/503` (honor `Retry-After`), discard non-retryable 4xx; offline queue FIFO cap ~200, drains on reconnect + foreground + opportunistically; breadcrumb ring cap 20; per-session sampling default 1.0. This doc decides the Flutter-specific gaps the canon leaves open.

---

## 1. Offline queue

### 1.1 Storage mechanism — file-per-batch (Q1)
One JSON file per queued batch under `getApplicationDocumentsDirectory()/edge_telemetry_queue/`, filename `<epochMs>_<seq>.json`. **No new dependency** — `path_provider` is already in `pubspec.yaml` and today's `CrashStorage` uses exactly this pattern; `OfflineQueue` generalizes it and `CrashStorage` is deleted (per #7). Drain = list the directory, sort by filename (lexical == chronological given zero-padded/epoch names), POST each, delete the file on `2xx`. Rejected: Hive/sembast (a new dep to reinvent a directory listing at a ~200-item scale), `shared_preferences` (rewrites the whole blob per mutation).

### 1.2 Unit of persistence — the assembled batch, verbatim (Q2)
The queue sits **below** `RetryTransport`, so anything reaching it is already an assembled envelope `{ type:"telemetry_batch", timestamp, batch_size, events:[...] }`. Persist it verbatim; **one file = one POST**; drain is a dumb replay (no re-batching, no re-timestamping). Queue depth is counted in **batches**, so cap ~200 = 200 batches (worst-case ≈ 6000 events — well within the Collector's `events`≤1000-*per-batch* limit, which each stored batch already respects). Immediate/crash sends are one-event batches and persist as single-event files naturally.

### 1.3 Eviction at cap — drop-oldest, crashes exempt (Q3)
At cap, a new failed batch evicts the **oldest non-crash** batch (recent telemetry > stale). **Crash batches are exempt from eviction** — a crash-loop while offline must not lose the crashes. The exemption rides the existing `crash_` filename prefix convention (a one-line `is-crash` check). Degenerate case (queue entirely crashes at cap): drop the oldest crash — bounded is bounded. Rejected: unconditional FIFO (evicts the most valuable data first), reject-newest (drops the just-happened crash).

### 1.4 De-duplication — none on-device (Q4)
Every crash occurrence is kept with its own timestamp + breadcrumbs. The backend already groups by fingerprint (`ErrorType_msgHash_stackHash`) — that is what the fingerprint is *for*. On-device dedup would trade away per-occurrence forensic detail to solve queue-flooding, which §1.3's cap + crash-exemption already bounds. YAGNI until real crash-loop flooding is observed.

### 1.5 Retry → queue handoff (Q5)
- **Offline** (`connectivity_plus` reports no connection) **or first attempt fails with status `0`** → skip the in-memory backoff, persist to the queue immediately; the reconnect/foreground drain recovers it. (No point burning 40s of timers when the radio is off.)
- **Online but erroring** (`429/503`) → run the full in-memory `[0, 2s, 8s, 30s]` schedule; persist to the queue only if all four attempts are exhausted.
- **Non-retryable 4xx** → discard (never queued).
- A **drain** POST that fails leaves/returns the file in the queue for the next drain trigger; no separate in-memory retry loop on the drain path. Runaway retention is bounded by §1.3's cap. Single branch: `if (offline || status == 0) queueNow() else runBackoffThenQueue()`.

---

## 2. Session model

### 2.1 Idle rotation — lazy last-activity check, no timer (Q6)
Every emitted event updates an in-memory `lastActivityAt`. On the **next** event (and on **resume**), if `now - lastActivityAt > 30 min`, finalize the old session and start a fresh one *before* emitting. **No `Timer.periodic`** — a backgrounded Flutter app can't run timers reliably (iOS suspends them), so a timer would be both wasteful and unreliable; idle only matters when the next activity arrives.

### 2.2 `paused` = flush + mark, NOT finalize (Q7, Q8)
This is the crux that reconciles "finalize on background" with the 30-min idle rule and avoids inflating session counts on every app-switch.

- **On `AppLifecycleState.paused`**: immediate-flush the Pipeline buffer (nothing lost to a subsequent kill) and record the background timestamp into `lastActivityAt`. **Do not finalize.**
- **On `resume`**: if `now - lastActivityAt > 30 min` → emit `session.finalized` for the old session (**backdated to `lastActivityAt`**) + `session.started` for a new one; if `< 30 min` → the same session continues (a brief app-switch does **not** rotate the session).
- **On next launch** (app was killed while backgrounded): a persisted stale `session.id` with no matching finalize → emit its `session.finalized` (backdated to the stored `lastActivityAt`), then start fresh. Because we always flush at `paused`, a kill loses no events — only the finalize event is deferred to next launch, and the file-backed queue (§1.1) carries it across the restart.
- We **never** rely on catching `detached`/terminate (unreliable on iOS force-quit / OS kills). `paused` is the one lifecycle signal iOS and Android both deliver reliably before a kill.

**Requires persistence** of `session.id` + `lastActivityAt` across launches → `shared_preferences` (already a dep). This is what makes kill-recovery work.

### 2.3 Journey summary on `session.finalized` (Q9)
`session.finalized` carries (all **new** attributes → flagged for backend accommodation, consistent with #4's orphan-event handling):

| Attribute | Meaning |
|---|---|
| `session.duration_ms` | wall-clock start→finalize (backdated end) |
| `session.event_count` | total events this session |
| `session.error_count` | non-fatal errors |
| `session.crash_count` | `app.crash` events |
| `session.screen_count` | distinct screens visited |
| `session.screen_journey` | ordered route path, e.g. `"/home>/cart>/checkout"`, **capped to last 20 hops** |
| `session.http_request_count` | HTTP requests observed |

Counters are already maintained by `SessionManager` (near-zero cost). `screen_journey` is the one genuinely-hard-to-reconstruct-backend-side signal (needs ordered sessionizing of raw nav events) and is worth deriving on-device; it is capped so a multi-hour session can't emit a giant attribute. Per-screen dwell times / network timelines were rejected — derivable backend-side from the raw events already sent (YAGNI on-device).

---

## 3. Sampling & priority — two orthogonal axes (Q10)

#7 §3.1 conflated send-priority with sampling-bypass. They are **separate axes** and the Collector must model them separately (not as one `priority` field):

- **Send priority** — `immediate` (`Pipeline.sendNow`) vs `batched` (`Pipeline.enqueue`).
- **Sampling** — `bypass` (always sent even in a sampled-out session) vs `subject-to-sample`.

| Event | Priority | Sampling |
|---|---|---|
| `app.crash` | immediate | bypass |
| `session.started` | immediate | bypass |
| `session.finalized` | immediate | bypass |
| `user.profile.update` | **batched** | **bypass** |
| everything else | batched | subject-to-sample |

`user.profile.update` is the discriminating case: identity mutations must **always** reach the backend (a sampled-out session dropping a name/email change corrupts the stored profile permanently → sampling-exempt), but they are **not** time-critical (no need to interrupt batching → stays batched). This is precisely why the two axes cannot be folded into one field.

Sampling is rolled **once per session** at `session.started` (`sessionSampleRate`, default 1.0) and stored as `session.sampled` in `ContextManager`; a sampled-out session drops **all** its `subject-to-sample` batched events (coherent journeys), while the bypass set above always sends.

---

## 4. Breadcrumbs (Q11)

Ring buffer cap 20 (family canon), **crash-scoped** — attached to `app.crash` as `crash.breadcrumbs`, never part of the global `ContextManager.snapshot()` (per #7 §3.1 step 3). Feed sources:

- **Auto**: navigation transitions (`NavCaptureHook`), HTTP requests — method + path + status, path already sanitized via existing `sanitizeUrl` (`HttpCaptureHook`), lifecycle changes (`LifecycleCaptureHook`).
- **Manual**: a new public `EdgeTelemetry.addBreadcrumb(message, {category, data})` for host-app crumbs.

Each crumb = `{ ts, category, message }`. Frames/metrics are **not** crumbed — they'd flood the 20-slot ring with noise and evict the high-signal nav/http trail.

---

## 5. Config surface (Q12, Q13)

Match the family's config posture: expose the few knobs consumers realistically tune; hardcode canon-parity constants (a consumer changing them only breaks alignment).

| Knob | Exposed? | Default |
|---|---|---|
| `sessionSampleRate` | ✅ config (added by #7) | `1.0` |
| `maxQueueSize` | ✅ config | `200` |
| `batchSize` | ✅ config (carried from `JsonEventTracker`) | `30` |
| `flushIntervalMs` | ✅ config | **`5000`** (see below) |
| retry schedule `[0,2s,8s,30s]` | ❌ internal constant | — |
| session idle timeout | ❌ internal constant | `30 min` |

### 5.1 Flush-interval reconciliation (Q13)
The family reference lists `flushIntervalMs ~5s`, but the current `JsonEventTracker` hardcodes `Timer(Duration(minutes: 5))` — a **60× discrepancy**. **Resolution: adopt the family's 5s** (`flushIntervalMs` default `5000`, config-overridable). The old 5-minute timer is a **latent defect** the refactor fixes: mobile sessions are frequently shorter than 5 min, so under the old timer most batched events never flushed on time and left only via the `paused`-flush (§2.2) or died with the app. 5s gives near-real-time delivery at family parity; the offline queue + batching still prevent request spam, and `paused`-flush covers backgrounding regardless.

---

## 6. New public API introduced by this ticket

Additive only (v2 back-compat preserved):
- `EdgeTelemetry.addBreadcrumb(message, {category, data})` — manual breadcrumb.
- Config fields: `maxQueueSize` (existing `flushIntervalMs`/`batchSize`/`sessionSampleRate` already present or added by #7).

These feed the **Terminology firewall** audit (map fog) — the public surface is now knowable once #11 (migration/deprecation) settles which OTel-era symbols survive.

## 7. Backend-accommodation requests raised here
- `session.finalized` journey-summary attributes (§2.3) — new keys/values the backend must store for session/funnel analytics.
- (Consistent with existing flagged requests in #2/#4/#6; rolls into the final deliverable's backend-requests list.)

## 8. What this doc does NOT decide
- **Native crash** capture mechanics feeding `CrashReporting` (`NativeCrash`/`ANR`/`Hang`, isolate listeners) → **#10**.
- **Migration/deprecation** of the public surface (which symbols deprecate vs hard-remove) → **#11**.
- **Refactor phasing** (which classes land in which phase) → map fog.
