# Flutter RUM SDK v2 — refactor phasing plan

Resolves [#13](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/13). Adapts Android's 4-phase
playbook (quick-wins → service extraction → tests → validation/alignment) to Flutter's v2.0.0, which — unlike
Android's zero-break refactor — ends in an intentional **wire break + first-ever native plugin layer + a
deprecation/hard-remove set**. This is the phased execution plan someone builds from; the map plans, it doesn't ship.

Inputs (the fixed change-set): architecture [#7](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/7),
OTel removal [#8](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/8), reliability/session
[#9](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/9), native crash
[#10](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/10), migration/deprecation
[#11](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/11), terminology firewall
[#12](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/12).

## Shipping model — split release

**Backward-compatible v1.x refactor first, then a terminal v2.0.0** for the intentional breaks. Android's
"refactor invisibly first" discipline, adapted to the fact that Flutter's god-object is *fused to the backend it
sheds*: the de-god-object work is entangled with removing the dual JSON/OTel machinery, so the invisible v1.x slice
is smaller than Android's was.

- **v1.6** = Phase 1 only (quick-wins) — genuinely wire- and API-invisible, ships and bakes in isolation.
- **v2.0.0** = Phases 2–5 — structural refactor + OTel removal + wire flip + reliability/session + native, all
  legitimately coupled. **Strictly atomic**: the whole set ships together or not at all.

Rejected: big-bang v2.0.0 (bundles reversible refactor risk with irreversible wire risk); doing service extraction
under v1.x behind span-shims or a deprecated OTel path (keeps the dual-backend complexity alive precisely through
the phase meant to kill it, and reopens #8's "hard-remove, no shim").

## Phases

### Phase 1 — Quick wins *(ships v1.6, backward-compatible)*
Delete dead `lib/src/telemetry/edge_telemetry.dart`; fix any resource/connection leaks; delete dead code. No
structural change, no wire change, no public-API change.

**Acceptance:** `flutter analyze` clean · existing tests green · **wire byte-identical to v1.5.2** (golden snapshot
unchanged) · **public-API diff = ∅** · dead file gone. Ships with its own tests.

### Phase 2 — Service extraction + OTel removal *(v2.0.0 dev)*
De-god-object the barrel (`lib/edge_telemetry_flutter.dart`) into the family 5-layer split
`Facade → Collector → Pipeline → RetryTransport → OfflineQueue` + `ContextManager` (per #7); facade = thin
singleton over DI'd core, barrel → exports only. Delete `SpanManager`/`EventTrackerImpl`/`event_tracker` interface,
`http/`, `monitors/`, `json_event_tracker`, and the `opentelemetry` dep. Apply the OTel **public break**: hard-remove
`startSpan`/`endSpan`/`activeScreenSpans` + `runAppCallback` + observer span ctor params; deprecate the 3 no-ops
(`useJsonFormat:false`, `withSpan`, `withNetworkSpan`). **Wire behaviour held constant** — pure restructuring.
**Publish the `drainNativeCrashes()` contract** here (the seam Phase 4's native track builds against in parallel).

**Acceptance:** 5 layers + `ContextManager` exist, barrel = exports only · `opentelemetry` removed from `pubspec` ·
**public-API diff = exactly the break set** (4 hard-removed + observer ctor params; 3 no-ops `@Deprecated` with
once-per-process debug-gated warn) · **wire STILL byte-identical to v1.5.2** (proves pure restructure) · the 6 seam
unit tests green · `drainNativeCrashes()` contract published.

### Phase 3 — Wire flip + reliability/session *(v2.0.0 dev)*
Flip the wire to family canon: envelope → `telemetry_batch`, `X-API-Key`, 12-event allowlist, `app.crash` shape,
extra-data glossary keys; SDK never sends `location`. Build reliability/session per #9: file-per-batch offline queue
(cap ~200 drop-oldest, crashes exempt), retry `[0,2s,8s,30s]`→queue, lazy last-activity session model
(`paused` = flush+mark, finalize on resume/next-launch), two-axis sampling (bypass vs immediate), breadcrumb ring 20,
**flush reconciled 5min→5s**. New additive API: `addBreadcrumb()`, `maxQueueSize`. Config renames (firewall #12):
`sampleRate`, `flushIntervalMs`, `batchSize`.

**Acceptance:** **wire snapshot matches family-canon fixtures** (envelope/auth/allowlist/`app.crash`/glossary keys) ·
session · two-axis-sampling · offline-queue · retry · breadcrumb tests green · flush = 5s · config renamed ·
`addBreadcrumb()`/`maxQueueSize` present.

### Phase 4 — Native plugin + native crash *(v2.0.0 dev, parallel track)*
Stand up the package's **first native layer** (iOS Swift **MetricKit**, Android Kotlin **ApplicationExitInfo + JVM
`UncaughtExceptionHandler`**) behind one `MethodChannel`; **zero hand-rolled signal handlers/watchdogs**. Pull-only
`drainNativeCrashes()` on init → Phase-3 crash rail. iOS **hard-14** Podfile floor (MetricKit-only, fallback deleted);
Android keeps low floor (native+ANR API 30+, pre-30 gap documented via `sdk.native_capture_tier`).

**Sequencing:** the *plugin* develops **in parallel** with Phases 2–3 against the Phase-2 `drainNativeCrashes()`
contract (it shares almost no code with the Dart refactor and is the highest-uncertainty, longest-lead work). Only
the **convergence** — wiring the drain into the now-existing rail + e2e — is ordered here, since native crashes can't
be *delivered* before Phase 3's rail exists.

**Acceptance:** plugin builds iOS + Android · MetricKit + AEI/JVM drain verified **on device matrix** ·
`drainNativeCrashes()` feeds Phase-3 rail e2e (fatal `app.crash` with `cause`) · iOS 14 Podfile floor set ·
`sdk.native_capture_tier` attr emitted · pre-API-30 native/ANR gap documented.

### Phase 5 — Tests + validation & backend alignment *(v2.0.0 dev, release gate)*
Tests are **woven per-phase** (each phase lands green); Phase 5 is the **system-level gate**, not "where testing
happens." It covers only what can't be written earlier: end-to-end wire snapshot vs canon, cross-phase integration,
public-API-diff assertion, coverage/perf benchmarks, backend-alignment validators, and the migration guide.

**Acceptance:** full cross-phase integration green · coverage/perf targets met (Android's <1ms event-record bar) ·
**backend-team sign-off** on the wire + all flagged accommodation requests (orphan events, new eventNames/attrs,
dashboard `sdk.platform` values) — the **destination-defining gate**: v2.0.0 cannot ship on engineering-green alone ·
migration guide + `CHANGELOG`/`README` complete.

## Ordering constraints
- `ContextManager`/Collector (P2) **before** offline queue/reliability (P3).
- OTel removal (P2) **before** terminology-firewall config renames (P3).
- Native plugin **contract** (P2) before the plugin builds; native **delivery** (P4) after Phase 3's crash rail.
- Wire held constant through P2, flipped in P3 — so P2's "pure restructure" is snapshot-verifiable.

## Risk sequencing
- **Phase 1 (v1.6) is the only independently-shippable slice.** Phases 2–5 are one **atomic v2.0.0** — no partial ship.
- **Highest risk = Phase 4 native** (first native layer, OS-diagnostic APIs, device-matrix verification) — hedged by
  developing it as a parallel track from a Phase-2 contract, so it doesn't serialise behind the Dart work.
- **Flagged contingency (not a sanctioned option):** if Phase 4 verification can't complete, the fallback is
  wire-first v2.0.0 (Phases 2–3) + native in **v2.1.0**. This **reopens [#10](https://github.com/NCG-Africa/edge_telemetry_flutter/issues/10)**
  (which ruled full native in-scope for v2.0.0) and must be surfaced as a deviation, never taken silently.
- **Consumer build-break to call out in the migration guide:** min iOS 14 Podfile (from #10's MetricKit floor).
