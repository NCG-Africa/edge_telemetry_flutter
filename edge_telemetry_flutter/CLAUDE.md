# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`edge_telemetry_flutter` — a published Flutter package (pub.dev, v2.0.0) providing automatic Real
User Monitoring: HTTP calls, crashes (Dart + native), navigation, performance, and sessions are
captured with a single `EdgeTelemetry.initialize()` call plus one `navigationObserver` line in
`MaterialApp`. Mobile only (iOS + Android).

Domain vocabulary lives in [`CONTEXT.md`](CONTEXT.md) — read it before naming anything new.

Note: the git repo root is the **parent** directory; this package lives in `edge_telemetry_flutter/`.
Sibling dirs (`bomayetu/`, `tiifu/`, `edge_telemetry_android/`) are unrelated projects.

## Commands

```bash
flutter pub get                                  # install deps
flutter analyze                                  # lint (flutter_lints + analysis_options.yaml)
flutter test                                     # run all tests
flutter test test/unit/models/report_data_test.dart   # single file
flutter test --name "substring of test name"     # single test by name
dart format lib test                             # format
```

Publishing: bump `version:` in `pubspec.yaml`, update `CHANGELOG.md`, then push a `vX.Y.Z` tag —
`.github/workflows/publish.yml` publishes to pub.dev via OIDC (tag-gated; no manual `flutter pub publish`).

## Architecture

### Five layers, one direction

```
EdgeTelemetry (lib/src/facade/)   ← the entire public API; singleton; owns TelemetryWiring
  → Collector (core/)             ← per-item gate: sample · merge context · attach breadcrumbs · allowlist · counters
    → Pipeline (core/)            ← buffers batched items (30 / 5s); sendNow() for the immediate rail
      → RetryTransport (core/)    ← POST + X-API-Key + backoff [0, 2s, 8s, 30s]
        → OfflineQueue (core/)    ← one JSON file per undeliverable payload, drained FIFO
```

`lib/edge_telemetry_flutter.dart` is **exports only** — the barrel god-object is gone. Capture hooks
(`capture/`) feed the Collector and each returns a dispose handle. Managers (`managers/`) own session,
context, identity, profile, breadcrumbs. `lib/main.dart` is a demo app shipped in the package, not the
library entry point.

### The wire is a closed contract

`lib/src/core/wire_canon.dart` holds the family canon: 12 event names, 4 metric names. **`Collector.add`
silently drops any batched item whose name is off-canon** — adding an event means adding it to the canon
first, or it never leaves the device. Envelope is `telemetry_batch`; POST goes to
`<endpoint>/collector/telemetry` with `X-API-Key`.

Attribute spelling is deliberately mixed and must not be "normalized": dotted for identity/domain keys
(`session.id`, `http.url`), **unprefixed** on `app.crash` (`message`, `stacktrace`, `exception_type`,
`cause`, `is_fatal`) because the backend extractors read those verbatim.

### Two rails, orthogonal to sampling

Crashes take the immediate rail (`EventPriority.immediate` → POSTed alone, single attempt, then
persisted with a `crash_` prefix that exempts them from the queue cap). Everything else batches.
Separately, the sampling roll happens **once per session**; crashes, session bookends, and
`user.profile.update` bypass it. Priority and bypass are independent — check both when adding an event.

### Session is lazy, never timed

`SessionManager` rotates on a last-activity check (30-min idle) evaluated on the next event or on
resume. `paused` = flush + mark, **not** finalize. A session killed by the OS is finalized, backdated,
on the next launch. No `Timer.periodic` — a backgrounded Flutter app cannot run one reliably.

### Native crash capture is pull-only

`ios/Classes/` (Swift, MetricKit — iOS 14 floor) and `android/src/main/kotlin/` (JVM
`UncaughtExceptionHandler` + `ApplicationExitInfo` on API 30+) record crashes the dying process could
never report. Dart calls `drainNativeCrashes()` once on init over the `edge_telemetry/native_crash`
channel; the payload shape in `lib/src/crash/native_crash_channel.dart` is the contract binding all
three languages — change it in lockstep or not at all.

### HTTP monitoring via HttpOverrides

`installGlobal()` sets `HttpOverrides.global`, wrapping every `HttpClient` to time requests and emit
`http.request`. It chains to any previous overrides. **Consumers must not set their own
`HttpOverrides.global` after init**, or tracking breaks.

## Working with me
- When reporting information to me, be extremely concise and sacrifice grammar for the sake of concision.
- Never add Claude/AI attribution trailers anywhere — no `Co-Authored-By: Claude`, no `🤖 Generated with Claude Code`, in commits, PRs, comments, or code.

## Guiding principles (Karpathy)
- Simplest thing that works. Smallest diff. Delete before you add.
- No black boxes — code you can hold in your head end-to-end; understand every line before shipping.
- Minimal, hackable, readable (nanoGPT/micrograd ethos) over clever or generic.
- No speculative abstraction — build for what's needed now, not imagined futures (YAGNI).
- Keep the human in the loop: small verifiable steps, inspect real data/output, don't trust code you haven't run.
- Strong opinions, loosely held — prefer the boring, proven approach; justify complexity or drop it.

## Conventions
- Public API changes stay backward compatible (deprecate, don't remove). `useJsonFormat`, `batchTimeout`,
  `maxBatchSize`, `eventBatchSize`, `withSpan`, `withNetworkSpan` are shipped no-ops kept for that reason —
  they go in v3.0.0.
- Terminology firewall on **new** public symbols and docs: no `span`, `trace`, `instrumentation`, `OTLP`,
  `OpenTelemetry`. Existing names are grandfathered.
- Debug output is `print()` guarded by `config.debugMode`; crash send/fail logs in `RetryTransport` are
  **intentionally always printed** — leave those un-guarded.
- Custom profile attributes are auto-prefixed with `user.`.
- Changes visible to consumers must land in `README.md` + `CHANGELOG.md`.
