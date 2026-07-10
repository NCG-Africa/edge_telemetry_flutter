# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`edge_telemetry_flutter` — a published Flutter package (pub.dev, v1.5.2) providing automatic Real User Monitoring: HTTP calls, crashes, navigation, performance, and sessions are captured with a single `EdgeTelemetry.initialize()` call plus one `navigationObserver` line in `MaterialApp`.

Note: the git repo root is the **parent** directory; this package lives in `edge_telemetry_flutter/`. Sibling dirs (`bomayetu/`, `tiifu/`, `edge_telemetry_android/`) are unrelated projects.

## Commands

```bash
flutter pub get                                  # install deps
flutter analyze                                  # lint (flutter_lints + analysis_options.yaml)
flutter test                                     # run all tests
flutter test test/unit/models/report_data_test.dart   # single file
flutter test --name "substring of test name"     # single test by name
dart format lib test                             # format
```

Publishing: bump `version:` in `pubspec.yaml`, update `CHANGELOG.md`, then `flutter pub publish`.

## Architecture

### The god-object lives in the barrel file
The entire `EdgeTelemetry` singleton (~1250 lines: public API + orchestration) is in **`lib/edge_telemetry_flutter.dart`** — the same file consumers import. `lib/src/telemetry/edge_telemetry.dart` is **empty** (dead file, ignore it). When editing the main class, edit the barrel.

`lib/main.dart` is a **demo app** shipped inside the package (not the library entry point), useful for manual testing against a local collector.

### Two telemetry backends, chosen by `useJsonFormat`
`initialize()` builds a `TelemetryConfig` then calls `_setup()`, which branches:
- **JSON mode (default, `useJsonFormat: true`)** → `JsonEventTracker` batches events and POSTs raw JSON to `endpoint` via `JsonHttpClient`. `_spanManager` stays null; all span/OpenTelemetry methods (`withSpan`, `startSpan`, `onSpanStart`) become no-ops.
- **OpenTelemetry mode** → `EventTrackerImpl` + `SpanManager` export spans through the `opentelemetry` SDK's `CollectorExporter`.

Everything funnels through the `EventTracker` interface (`lib/src/core/interfaces/event_tracker.dart`), so most call sites are format-agnostic. When adding a feature, check whether it needs both paths or is OpenTelemetry-only (guard the latter with `if (!_config!.useJsonFormat && _spanManager != null)`).

### Automatic HTTP monitoring via HttpOverrides
`TelemetryHttpOverrides.installGlobal()` sets `HttpOverrides.global`, wrapping every `HttpClient`/request/response (`lib/src/http/telemetry_http_overrides.dart`) to time requests and emit `http.request` / `http.error` / `http.slow_request` events. It chains to any previous overrides. **Consumers must not set their own `HttpOverrides.global` after init**, or tracking breaks.

### Attribute enrichment pipeline
Every event/metric passes through `_getEnrichedAttributes()`, which merges `_globalAttributes` (device + app info + `user.id`) + live session attributes + `network.type` + optional breadcrumbs. `trackEvent`/`trackMetric` accept `dynamic` attributes (Map, object with `toJson()`, or arbitrary object) coerced to `Map<String,String>` by `_convertToStringMap`.

### Crash path is separate from batching
`JsonEventTracker.trackError` **bypasses the batch queue** and sends immediately. On network failure it persists to `CrashStorage` (offline files); `CrashRetryManager` retries with exponential backoff (1→2→4min…1hr, max 3 attempts). Crashes get a fingerprint (`ErrorType_msgHash_stackHash`) for grouping and carry breadcrumbs (`BreadcrumbManager`, capped ring buffer) for context.

### Managers & collectors (`lib/src/`)
- `managers/` — `SessionManager` (session lifecycle + stats), `UserIdManager`/`DeviceIdManager` (persistent auto-generated IDs via `shared_preferences`), `BreadcrumbManager`, `CrashRetryManager`, profile versioning.
- `monitors/` — `FlutterNetworkMonitor` (connectivity_plus), `FlutterPerformanceMonitor` (frame/memory).
- `collectors/` — `FlutterDeviceInfoCollector` (device_info_plus + package_info_plus).
- `reports/` + `storage/` — local reporting (opt-in `enableLocalReporting`), currently backed by in-memory storage only.
- `widgets/EdgeNavigationObserver` — the `NavigatorObserver` consumers wire into `MaterialApp`.

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
- Attribute keys are dotted namespaces: `http.*`, `user.*`, `session.*`, `device.*`, `app.*`, `network.*`, `crash.*`. Custom profile attributes are auto-prefixed with `user.`.
- Debug output is `print()` guarded by `_config.debugMode`; error-report send/fail logs are **intentionally always printed** (unconditional) — leave those un-guarded.
- Public API changes must stay backward compatible (deprecate, don't remove — see `runAppCallback`) and be reflected in `README.md` + `CHANGELOG.md`.
