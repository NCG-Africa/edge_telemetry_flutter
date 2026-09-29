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

`lib/src/core/wire_canon.dart` holds the family canon: 16 event names, 4 metric names. **`Collector.add`
drops any batched item whose name is off-canon** — adding an event means adding it to the canon
first, or it never leaves the device. The drop is a hard drop and stays one; from v3 it is no longer
silent — a `debugMode` log naming the item, plus a dropped-item counter on `session.finalized`.
Envelope is `telemetry_batch`; POST goes to
`<endpoint>/collector/telemetry` with `X-API-Key`.

Attribute spelling is deliberately mixed and must not be "normalized": dotted for identity/domain keys
(`session.id`, `http.url`), **unprefixed** on `app.crash` (`message`, `stacktrace`, `exception_type`,
`cause`, `is_fatal`) because the backend extractors read those verbatim.

### Six rules govern the canon

There is no family canon register and no ratifying body — the allowlist is a union of whatever shipped
first (#53, amended by #61):

1. **Conform where a sibling already ships the name**, decide locally where none does, and never block
   a release on ratification.
2. **No renames of a v2 name, ever** — deprecate-in-place. A name may stop being emitted; it may never
   be renamed or have its meaning changed under the same backend columns. `page_load` therefore means
   app launch forever, and screen load minted a new name instead.
3. **Attribute-first, by a *temporal* test**: a signal earns an event name only when no existing event
   fires at the instant that signal is known. Otherwise it is attributes on that event.
4. **Ceiling: 6 new event names, 0 new metric names** — derived from the item budget, not picked.
5. **The change request is a co-signature** on the sibling's bag-first JSONB proposal, not a proposal
   awaiting approval. Because the raw key is always stored, promoting it to a typed column later is a
   backfill, so a ship date here and a column date there are independent.
6. **The allowlist stays a hard drop; the drop becomes visible.** The drop is the only device-side
   guard against an unbudgeted emitter. The *silence* was the bug — six emissions were dropped on
   every device through all of v2 and found by audit, not by telemetry.

Corollary, earned three times on this map: **a summary of a sibling is evidence about the summary.**
Read the sibling's source or spec directly before building on a claim about it.

### Two rails, orthogonal to sampling

Crashes take the immediate rail (`EventPriority.immediate` → POSTed alone, single attempt, then
persisted with a `crash_` prefix that exempts them from the queue cap). Everything else batches.
Separately, the sampling roll happens **once per session**; crashes, session bookends, and
`user.profile.update` bypass it. Priority and bypass are independent — check both when adding an event.

### Tiers gate at the capture hook

`essential` / `standard` / `diagnostic`. A tier is a collection level — an on/off plus a shed rank —
and **never a sampling axis**; per-tier rates would make the once-per-session roll incoherent. Tiers
gate **at the capture hook**, before the attribute map is built, never at the Collector, which would
build the map and spend the CPU only to discard the item. The budget governor sheds **whole tiers** in
shed-rank order — `diagnostic`, then `standard`, never `essential` — and never individual signals.
`essential` is exactly v2's shipped sampling-bypass set: crash, session bookends, profile update.

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
- **Deprecate-in-place — names are retained, emission stops or changes.** The cycle is an annotation on
  **every** declaration naming the removal version (the clause that catches a missed field), a shipped
  release, a changelog line, and a runtime warning wherever behaviour *changes* rather than disappears.
  Every v3 deprecation names v4.0.0. Currently deprecated-in-place: `user.interaction`,
  `frame_render_time`, `resource_timing`, `screen.duration`.
- Terminology firewall on **new** public symbols and docs — an **anti-OpenTelemetry** rule, not an
  anti-tracing one (#56): banned are `instrumentation`/`instrument`, `OTLP`, `OpenTelemetry` and OTel
  class names (`tracer`, `SpanProcessor`, `SpanExporter`). `trace` and `span` are **permitted** where
  they name the W3C `traceparent` concept. Use `capture`, never `instrument`, for wrapping a
  consumer's client. Existing names are grandfathered; the wire (`eventName`/attr keys) is out of scope.
- The `Capture` enum is **closed at the `essential` boundary on purpose** — there is no `crash`,
  `session`, `error` or `profile` member, because an SDK reporting no crashes must never be
  indistinguishable from one configured not to. **Do not complete it for symmetry.** Adding a member
  is a decision about what a consumer may switch off, not a gap in an enumeration.
- Debug output is `print()` guarded by `config.debugMode`; crash send/fail logs in `RetryTransport` are
  **intentionally always printed** — leave those un-guarded.
- Custom profile attributes are auto-prefixed with `user.`.
- Changes visible to consumers must land in `README.md` + `CHANGELOG.md`.
