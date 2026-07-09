# Flutter Extra-Data Glossary — the "capture more" mandate

> Wayfinder ticket [#5](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/5).
> **Flutter-unique** signals the v2 SDK should capture *beyond* the family canon, each for backend-team review.
> Companion to [`family-alignment-reference.md`](./family-alignment-reference.md) (canon target),
> [`eventname-envelope-mapping.md`](./eventname-envelope-mapping.md) (the locked wire mapping this extends), and
> [`before-inventory.md`](./before-inventory.md) (current state).
> Decision session: `/grilling`, 2026-07-09.

## Inclusion bar (the filter every candidate cleared or failed)

A signal earns a place in the **recommended set** only if **all three** hold:

1. **Canon-can't** — diagnoses something `frame_render_time` / `memory_usage` / `http.request` / `app.crash` / `navigation` can't already.
2. **Passive & cheap** — captured from a callback/binding already running for the canon; no polling loop, no per-frame allocation, no interception in a hot path, no host code.
3. **Zero PII / zero app-secret** — no verbatim route arguments, no user content, no app internals.

Fail a rung → **evaluated-and-rejected appendix** (documented, so the backend team sees it was considered), not the recommended set.

## Attribute-key style (inherited from ticket #4, applied here)

Per the #4 rule: **dotted** for identity/http/nav/screen/session/user namespaces; **dotless** for frame/memory *metric internals*; **unprefixed** for `app.crash` keys. Every recommended key below complies.

---

## Recommended set (INCLUDE)

All items are **additive**: flat primitives attached to an **existing canon event/metric** — no new `eventName`, no new envelope. Backend accommodation = extra keys/columns only; no schema-registration step (per [`collector-ingestion-contract.md`](./collector-ingestion-contract.md)).

### 1. Frame phase split — UI (build) vs raster (GPU)

- **Metric:** `frame_render_time` (canon). `value` stays total frame time.
- **Keys** (dotless, metric internals):
  - `build_time_ms` (number) — UI-thread build+layout duration.
  - `raster_time_ms` (number) — raster-thread GPU duration.
- **Source:** `SchedulerBinding.instance.addTimingsCallback` → `FrameTiming.buildDuration` / `.rasterDuration`. The **same** callback the canon metric already uses → **zero extra cost**.
- **Value:** the entire jank-triage decision — is a dropped frame Dart-side (heavy build/layout) or GPU-side (overdraw/shaders)? The single canon number can't say.
- **Additive.** Two extra number columns.

### 2. Crash source

- **Event:** `app.crash` (canon).
- **Key** (unprefixed, per #4 crash rule):
  - `source` (string) — one of `flutter_error` | `platform_dispatcher` | `zone` | `isolate`.
- **Does NOT reopen #4's `cause` discriminator** — `cause=Error` stays for all Dart; `source` is a finer sub-attribute of *where* the error entered.
- **Value:** today all Dart errors funnel to `cause=Error`, losing origin. A background-isolate crash and a UI zone error are different bugs.
- **Capture note (mechanics, not glossary):** the audit hooks only `FlutterError.onError` + `PlatformDispatcher.onError`. Uncaught **spawned-isolate** errors reach neither — they need an explicit `Isolate.current.addErrorListener`. Wiring that listener is a prerequisite for `source=isolate` to ever fire; flagged to the crash-capture design.
- **Additive.** One extra string column.

### 3. Route type (+ args-present flag, NOT args)

- **Event:** `navigation` (canon). Also enriches `screen.duration`.
- **Keys** (dotted, matches existing `route.*` in code + #4 nav rule):
  - `route.type` (string) — runtime `Route` type, e.g. `MaterialPageRoute`, `DialogRoute`, `ModalBottomSheetRoute`, `PopupRoute`.
  - `route.has_arguments` (bool) — were args passed? — **never the argument values.**
- **Source:** the `Route` object in the `NavigatorObserver` already running for the canon `navigation` event.
- **Value:** a dialog/bottom-sheet dwell reads very differently from a full-page dwell; `has_arguments` lets a flow be reproduced without leaking its data.
- **Additive.** One string + one bool.
- **Hard boundary:** raw `RouteSettings.arguments` is **never** captured (see appendix — PII).

### 4. Cold-start timing

- **Event:** `page_load` (canon; #4 mapped `performance.app_startup` → `page_load`).
- **Keys** (dotted, matches existing `startup.*`):
  - `startup.type` (string) — `cold` | `warm`.
  - `startup.time_to_first_frame_ms` (number) — measured via `WidgetsBinding.instance.addPostFrameCallback` from the earliest SDK-reachable timestamp.
- **Documented limitation:** `time_to_first_frame_ms` is **SDK-init-relative, not process-relative** — it undercounts by everything before `EdgeTelemetry.initialize()`. Accurate only if the host calls `initialize()` as early as possible in `main()`. State this in the public docs.
- **Additive.** One string + one number.
- **Deferred:** the true native engine-init phase split (process-spawn → engine → `main()`) needs per-platform native timeline hooks — see appendix.

### 5. Lifecycle sub-state

- **Event:** `app_lifecycle` (canon). Canon primary semantics (foreground/background) unchanged.
- **Key** (dotted):
  - `lifecycle.state` (string) — raw Flutter `AppLifecycleState`: `resumed` | `inactive` | `paused` | `hidden` | `detached`.
- **Source:** `WidgetsBindingObserver.didChangeAppLifecycleState` — the observer already registered for the canon event.
- **Value:** Flutter models finer states than the other platforms uniformly do. `inactive` (transient — app switcher, incoming call) vs `paused` (truly backgrounded) sharpens session-boundary and battery-context analysis.
- **Additive.** One extra string column.

### 6. Rendering / accessibility context

- **Scope:** device context (merged into every event via the enrichment pipeline).
- **Keys** (dotted, `device.*`):
  - `device.platform_brightness` (string) — `light` | `dark`. **Benign.**
  - `device.text_scale_factor` (number) — ⚠️ **sensitivity-flagged.**
  - `device.reduce_motion` (bool) — from `disableAnimations`. ⚠️ **sensitivity-flagged.**
- **Source:** `PlatformDispatcher.instance` (`platformBrightness`, `textScaleFactor`, `accessibilityFeatures.disableAnimations`) — one-shot + change callbacks, fully passive.
- **Value:** all three contextualize perf — dark mode changes rendering cost; large text reflows layout (→ more jank); reduced-motion changes frame profiles.
- **⚠️ Privacy note (rides to backend review):** `text_scale_factor` and `reduce_motion` are **accessibility settings** — a sensitive-adjacent category that can *infer* a user impairment. Not identity-PII, but they brush the bar. **Required:** backend/privacy review before first-class storage, and a **config opt-out** gating their capture. `platform_brightness` carries no such flag.
- **Additive.** One string + one number + one bool.

---

## Evaluated & rejected (documented for the backend team)

| Candidate | Verdict | Why | Revisit trigger |
|---|---|---|---|
| **Platform-channel (method-channel) latency** | REJECT | Not passive — needs a `BinaryMessenger` interception layer in the hot path of every plugin call; mostly third-party code, not the app's; channel/args risk leaking internals/PII. Fails rung 2. | A concrete plugin-latency incident that justifies the interception cost. If revisited: `platform_channel.name` / `.method` / `.duration_ms` — **never** arguments. |
| **Raw route arguments** | REJECT (hard) | `RouteSettings.arguments` is arbitrary app data (user IDs, order objects, free-form maps). Verbatim capture = rung-3 PII violation. | Never. `route.has_arguments` (bool) is the permitted compromise. |
| **Native engine-init phase split** (app-start breakdown) | DEFER | The pre-Dart native phase (process spawn → engine init → `main()`) isn't visible passively from Dart; needs per-platform native timeline hooks. Fails rung 2. Overlaps native instrumentation. | When native instrumentation lands (see native-crash ticket [#10](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/10)) — then add `startup.engine_init_ms` / `startup.dart_init_ms`. |
| **Widget rebuild counts / jank attribution** | REJECT | No release-mode passive source — needs `debugProfileBuildsEnabled` / inspector timeline (debug-only, stripped in release) or per-`build()` instrumentation. Fails rung 2. Frame build/raster split already localizes jank to UI-vs-GPU; per-widget attribution is a DevTools profiling task, not fleet RUM. | Not planned. |
| **Dart VM / GC signals** | REJECT | GC events / VM internals are exposed only via the VM service protocol — **disabled in profile/release**. No release-safe public GC hook. RSS (the one release-safe VM-ish signal) already feeds `memory_usage`. | If Dart ships a release-safe GC callback. |

---

## Backend-team summary (what accommodation this asks for)

**No new eventNames, no new metrics, no envelope change.** Every recommended signal is a **flat primitive attribute on an existing canon event/metric**. Accommodation is limited to accepting/storing extra keys:

- On `frame_render_time`: `build_time_ms`, `raster_time_ms`
- On `app.crash`: `source`
- On `navigation` (+`screen.duration`): `route.type`, `route.has_arguments`
- On `page_load`: `startup.type`, `startup.time_to_first_frame_ms`
- On `app_lifecycle`: `lifecycle.state`
- Device context (all events): `device.platform_brightness`, `device.text_scale_factor`, `device.reduce_motion`

**Two items need explicit privacy sign-off before first-class storage:** `device.text_scale_factor` and `device.reduce_motion` (accessibility-sensitive; SDK will gate them behind a config opt-out).
