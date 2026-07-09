# Native crash capture mechanics (iOS + Android) — #10

> Resolves [#10](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/10). Companion to
> [`eventname-envelope-mapping.md`](./eventname-envelope-mapping.md) §3 (`app.crash` shape + `cause` taxonomy),
> [`reliability-session-model.md`](./reliability-session-model.md) (#9 offline queue + immediate crash rail),
> [`target-module-architecture.md`](./target-module-architecture.md) (#7 `CrashReporting`).

Native crashes (`cause` ∈ `NativeCrash` / `ANR` / `Hang`, `is_fatal:true`) can't be caught by Dart handlers.
This specs how they are captured on the native side and surfaced as `app.crash` events.

## 0. Decisions (the forks that were open)

| Fork | Decision |
|---|---|
| **Scope in v2.0.0** | **Full native, both platforms.** iOS + Android ship in v2.0.0 → 100% `cause` coverage at launch (`Error`, `NativeCrash`, `ANR`, `Hang`). No v2.x split. |
| **Capture strategy** | **OS diagnostic APIs first** — Apple **MetricKit** + Android **ApplicationExitInfo**. The OS does the async-signal-safe capture; we read reports on next launch. **Zero hand-rolled signal handlers or watchdog threads.** |
| **iOS floor** | **Hard floor iOS 14.** Pure MetricKit; the NSException/hang-watchdog fallback is **deleted, not written**. |
| **Android floor** | **Keep the existing low floor** (no user exclusion — Africa-market devices on 9/10 stay supported). JVM `UncaughtExceptionHandler` on **all** versions; native + ANR only on **API 30+** via `ApplicationExitInfo`. Pre-30 native/ANR is a **documented gap**, not a hand-rolled handler. |
| **Bridge** | Native queries the OS APIs **on SDK init (next launch)**, converts each *new* report to an `app.crash` payload, hands it over the platform channel to Dart, which routes it into **#9's immediate crash rail** (bypass batch → offline-queue with crash-exempt eviction). |
| **Dedup** | MetricKit self-dedups (Apple delivers each payload once). `ApplicationExitInfo` returns a rolling history → persist a **watermark** (last-seen exit timestamp) in `shared_preferences`; emit only newer records. |
| **Symbolication** | **Server-side** (family canon; backend already computes `crash_hash`/`severity`). Client sends **raw / best-effort** `stacktrace` + `exception_type` verbatim. No on-device symbol tooling. |

## 1. New plugin layer (prerequisite)

The package is **pure-Dart today** — no `ios/` or `android/` native folders exist. Native capture requires
introducing the package's **first platform-channel layer**: an iOS (Swift) unit + an Android (Kotlin) unit
behind one `MethodChannel` (`edge_telemetry/native_crash`). This is a phasing prerequisite (flag for the
refactor-phasing plan) — it is net-new native surface, kept deliberately thin by the OS-API choice.

Channel is **pull-only, one method**: Dart calls `drainNativeCrashes()` once during init; native returns a
`List<Map>` of new `app.crash` payloads (may be empty). No push, no streaming, no live callbacks — a crashing
process can't call Dart anyway, so next-launch pull is the only model that works.

## 2. iOS — MetricKit (iOS 14+)

Register an `MXMetricManagerSubscriber` at plugin init.

| MetricKit source | → `cause` | `is_fatal` | notes |
|---|---|---|---|
| `MXCrashDiagnostic` | `NativeCrash` | `true` | signal/exception crashes (ObjC/Swift/native) |
| `MXHangDiagnostic` | `Hang` | `true` | main-thread hang (per #4 taxonomy; kept fatal even though app may recover) |

- Delivery is **next-launch, batched by Apple** (can lag a launch or two — accepted; crashes aren't real-time anyway).
- `didReceive([MXDiagnosticPayload])` → cache payloads to a native file; `drainNativeCrashes()` reads + clears them.
- **No watermark needed** — MetricKit delivers each payload exactly once.
- Payload map (§4) from `callStackTree` (raw frames), `MXCrashDiagnosticMetaData` (`exceptionType`, `signal`,
  `terminationReason` → `exception_type`; `signal`/reason → `message`).

## 3. Android — tiered by API

Single Kotlin unit, two sources reconciled to avoid double-reporting:

| Source | API | catches | → `cause` | `is_fatal` |
|---|---|---|---|---|
| `Thread.setDefaultUncaughtExceptionHandler` | **all** | JVM/Kotlin uncaught | `NativeCrash` | `true` |
| `ActivityManager.getHistoricalProcessExitReasons` (`ApplicationExitInfo`) | **30+** | `REASON_CRASH_NATIVE`, `REASON_ANR` | `NativeCrash` / `ANR` | `true` |

- **JVM handler**: persists the throwable (message + stacktrace) to a native file, then chains to the previous
  handler and lets the process die. Read + emitted next launch. Works on every API level.
- **`ApplicationExitInfo`** (API 30+): on init, list exit reasons since the watermark; map `REASON_CRASH_NATIVE`
  → `NativeCrash` (tombstone `traceInputStream`), `REASON_ANR` → `ANR` (ANR trace). Persist the newest
  `timestamp` as the watermark in `shared_preferences` (native reads the same prefs key Dart uses).
- **Dedup boundary (API 30+):** `ApplicationExitInfo` *also* reports `REASON_CRASH` (JVM), which the live
  handler already recorded → **ignore `REASON_CRASH` from `ApplicationExitInfo`**; the JVM handler is the single
  source for JVM crashes. `ApplicationExitInfo` contributes only `REASON_CRASH_NATIVE` + `REASON_ANR`.
- **pre-30 gap (documented):** native (NDK) crashes and ANRs are **not** captured below API 30. JVM crashes
  still are. No NDK sigaction, no ANR watchdog — the OS-API-first decision explicitly trades this tail for zero
  async-signal-safe native code. Emit an `sdk.native_capture_tier` context attribute (`full` / `jvm_only`) so
  the backend can see coverage per device.

## 4. Payload → `app.crash` (from #4 §3)

Native builds the `app.crash` attribute map with the **unprefixed** crash keys, then Dart merges identity
context (`ContextManager.snapshot()`, per #7) before sending:

| key | iOS (MetricKit) | Android |
|---|---|---|
| `message` | signal + termination reason | throwable message / exit `description` |
| `stacktrace` | `callStackTree` (raw, unsymbolicated) | stacktrace / tombstone / ANR trace (raw) |
| `exception_type` | `exceptionType` / `signal` | throwable class / `REASON_*` |
| `cause` | `NativeCrash` \| `Hang` | `NativeCrash` \| `ANR` |
| `is_fatal` | `true` | `true` |
| `crash.source` | `metrickit` | `uncaught_handler` \| `app_exit_info` |

- `stacktrace` is **raw** — server symbolicates (dSYM / NDK symbols uploaded backend-side).
- Server still computes `crash_hash`, `severity_level`, `breadcrumbs` (client doesn't send these, per #4).

## 5. Bridge flow (ties to #9)

```
app launch
  └─ EdgeTelemetry.initialize()
       └─ drainNativeCrashes()               // MethodChannel, once
            ├─ iOS:    cached MXDiagnosticPayloads → [app.crash maps]
            └─ Android: JVM crash files + ApplicationExitInfo(>=watermark) → [app.crash maps]
       └─ for each map:
            CrashReporting.report(map)         // #7
              └─ immediate send, bypass batch  // #9 §crash rail
                   └─ on failure → offline queue (crash-exempt eviction, #9 §1.3)
```

- Each native crash is a **one-event `telemetry_batch`** (matches #9's immediate-send unit).
- Cross-launch persistence on the **native** side (files + watermark) mirrors #9's Dart-side offline queue —
  same "persist because we can't POST from a dying process, replay on next launch" principle, one layer lower.
- No on-device dedup of crash *content* (per #9 §1.4) — the watermark only prevents **re-reading the same OS
  record**, not de-duplicating distinct occurrences.

## 6. Backend requests flagged

1. **Server-side symbolication** for raw iOS `callStackTree` + Android tombstone/NDK stacks (needs dSYM /
   symbol upload infra backend-side). Confirm this exists or is planned.
2. New context attr **`sdk.native_capture_tier`** (`full` / `jvm_only`) — accommodate as a passthrough attr so
   coverage gaps are visible in the dashboard.
3. Confirm the backend tolerates `cause` values `NativeCrash` / `ANR` / `Hang` on `app.crash` (taxonomy from #4).

## 7. Rejected / not built

- **PLCrashReporter / Breakpad / Crashpad** — heavy C/C++ deps in a plugin; MetricKit + ApplicationExitInfo
  give the same next-launch reports for free on the supported floors.
- **Hand-rolled `sigaction` / NSException handlers / ANR + hang watchdog threads** — async-signal-safe native
  code is the classic 3am pager; the OS APIs do it correctly. Pre-30 Android native/ANR gap is accepted instead.
- **Client-side symbolication** — contradicts the family thin-client model; no on-device symbol tooling.
- **Real-time / push bridge** — impossible from a dying process; next-launch pull is the only workable model.
