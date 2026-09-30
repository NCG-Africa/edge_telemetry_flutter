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
context, trace, identity, profile, breadcrumbs. `lib/main.dart` is a demo app shipped in the package, not the
library entry point.

### The wire is a closed contract

`lib/src/core/wire_canon.dart` holds the family canon: 16 event names, 4 metric names. **`Collector.add`
drops any batched item whose name is off-canon** — adding an event means adding it to the canon
first, or it never leaves the device. The drop is a hard drop and stays one; from v3 it is no longer
silent — a `debugMode` log naming the item, plus a dropped-item counter on `session.finalized`.
Envelope is `telemetry_batch` and **both rails send it** — a crash is a one-item batch, not a
bare item (a bare item is what the collector 400'd through all of v2). POST goes to
`<endpoint>/collector/telemetry` with `X-API-Key`, gzipped; a 400 on a compressed body
triggers one uncompressed re-POST per launch, and that probe is the only capability check.

The envelope also has an optional flat-dotted `context` block — the batch-level hoist, gated by
`kHoistBatchContext` in `wire_canon.dart`, **default off and never a config field**. It fails
*silently* against an unmerged processor (unknown block dropped → every session arrives with an
empty `session.id`), so it flips only in the release after the server-side merge lands. When on,
the Collector splits identity out of each batched item (classified by dotted prefix, so every
live `device.*` value is batch-scoped, not just `platform_brightness`), mutable session counters
leave the wire
(they ride only the two bookends, on the never-hoisted immediate rail), and the Pipeline flushes
whenever the block changes — one batch is structurally one session and one user.

Attribute spelling is deliberately mixed and must not be "normalized": dotted for identity/domain keys
(`session.id`, `http.url`), **unprefixed** on `app.crash` (`message`, `stacktrace`, `exception_type`,
`cause`, `is_fatal`, `handled`) because the backend extractors read those verbatim. Two v3 additions
sit there and **both are dotted**: the error taxonomy (`error.category`, `error.category_source`)
and the fatal-only fault bundle (#91: `device.battery_level`, `device.battery_charging`,
`device.power_save_mode`, `device.thermal_state`, `device.orientation`), beside the already-dotted
`crash.source` / `crash.breadcrumbs` — new keys the extractors do not read get the family's ordinary
spelling, not the legacy one. `cause` is a shipped enum here and free text in the sibling, so
no-renames keeps the taxonomy out of it.

### Six rules govern the canon

There is no family canon register and no ratifying body — the allowlist is a union of whatever shipped
first (#53, amended by #61):

1. **Conform where a sibling already ships the name**, decide locally where none does, and never block
   a release on ratification.
2. **No renames of a v2 name, ever** — deprecate-in-place. A name may stop being emitted; it may never
   be renamed or have its meaning changed under the same backend columns. `page_load` therefore means
   app launch forever, and screen load minted a new name instead.
   **Four v3 carve-outs, all deliberate** — three in §8 (#85): `http.duration_ms` re-bases,
   `http.success` narrows to 2xx, and `http.url` loses its query; and one in §10 (#91):
   `memory_usage` re-bases from resident set to the platform's own quantity (`phys_footprint` /
   total PSS). The rule bends only where the v2 meaning was *wrong* rather than merely different —
   a duration that measured neither connect nor download, a success that disagreed with the sibling
   SDK, a key shipping PII, and a memory figure that was the wrong number on **both** platforms and
   not comparable between them. Each bend that changes a value under an unchanged column carries an
   in-band flag: `http.url_redacted`, and `memory.source`. Record the errata; do not generalise this.
3. **Attribute-first, by a *temporal* test**: a signal earns an event name only when no existing event
   fires at the instant that signal is known. Otherwise it is attributes on that event.
4. **Ceiling: 6 new event names, 0 new metric names** — derived from the item budget, not picked.
5. **The change request is a co-signature** on the sibling's bag-first JSONB proposal, not a proposal
   awaiting approval. Because the raw key is always stored, promoting it to a typed column later is a
   backfill, so a ship date here and a column date there are independent.
6. **The allowlist stays a hard drop; the drop becomes visible.** The drop is the only device-side
   guard against an unbudgeted emitter. The *silence* was the bug — seven emissions were dropped on
   every device through all of v2 and found by audit, not by telemetry.

Corollary, earned three times on this map: **a summary of a sibling is evidence about the summary.**
Read the sibling's source or spec directly before building on a claim about it.

### Two rails, orthogonal to sampling

The rail is chosen by **fatality, not by being a crash**: a fatal — every native crash, ANR and
hang — takes the immediate rail (`EventPriority.immediate` → its own one-item batch, single
attempt, then persisted with a `crash_` prefix under its own 50-file cap), because its process
will not survive to the next flush. **A non-fatal error batches** (#90): its process lives, so it
earns the pipeline's retries and the offline queue, and one error in a `build()` method is items
in a batch rather than N single-attempt POSTs each carrying the whole crumb ring. Everything else
batches. **Nothing on the wire is exempt from a cap or an attempt ceiling** — a 4xx is dropped
and counted by status, never retried, never queued, because an undeliverable payload that
cannot die is what re-POSTed the whole v2 crash backlog after every successful send. Non-fatals
have their own two: 5 per exception-type-and-top-frame, 50 per session, overflow counted as
`error_cap` on the bookend; the dedup key is client-local and **never sent**, because the server
owns crash hashing. Separately, the sampling roll happens **once per session**; crashes (both
rails), session bookends, and `user.profile.update` bypass it. Priority and bypass are
independent — check both when adding an event.

### Tiers gate at the capture hook

`essential` / `standard` / `diagnostic`. A tier is a collection level — an on/off plus a shed rank —
and **never a sampling axis**; per-tier rates would make the once-per-session roll incoherent. Tiers
gate **at the capture hook**, before the attribute map is built, never at the Collector, which would
build the map and spend the CPU only to discard the item. The budget governor sheds **whole tiers** in
shed-rank order — `diagnostic`, then `standard`, never `essential` — and never individual signals.
`essential` is exactly v2's shipped sampling-bypass set: crash, session bookends, profile update.

### Trace context is ambient, and expiry is somebody's read

`TraceManager` holds the one open root and merges into `ContextManager.snapshot()` as a second
delegate, so **a capture hook that never touches trace context cannot forget it** — the structural
fix for the bug class that silently dropped seven emissions. Ambient is **exactly three keys**
(`trace.id`, `rum.action.id`, `trace.root_type`); `span.id`/`parent.span.id` are minted per
referenceable item by the single `startChild()` call and are never ambient.

Expiry (2 s idle, 10 s cap, session mismatch) runs in `TraceManager`'s **read accessors, not the
Collector** — the freeze happens inside the request override and never passes through
`Collector.add` at all. So the snapshot read is side-effecting; that is safe because expiry is
monotonic and idempotent, and unavoidable under the no-timer rule. Clear-on-`paused` is load-bearing
(Dart has no elapsed-realtime analogue). Construction order is strict: **session → trace → context**.

`EdgeEvent.ownsTraceContext` is the **fourth** orthogonal axis (beside priority, sampling bypass and
session counting): it makes the Collector strip those three ambient keys before merging the item's
own frozen copy, because *absence cannot beat presence in a spread*. `screen.id` is `SessionManager`'s
(session-scoped, minted in `recordScreen`) and a screen visit is **deliberately not a span** — it
would give an in-tap request two candidate parents.

### Session is lazy, never timed

`SessionManager` rotates on a last-activity check (30-min idle) evaluated on the next event or on
resume. `paused` = flush + mark, **not** finalize. A session killed by the OS is finalized, backdated,
on the next launch. No `Timer.periodic` — a backgrounded Flutter app cannot run one reliably.

### Health is not a time series

No cadence, no timer, no continuous device-state event — a stream graduates only when a
named consumer needs it, and there is none. v2's 10-second memory sample, 30-second
system check and threshold `memory_pressure` event are **deleted** (−58 items/session).
Two signals remain. **Memory at the two session bookends** (`MemoryBookendHook`): opened
from `SessionManager.onSessionStart`, closed once per session on `paused` — *not* on
finalize, because the common ending is the OS killing a backgrounded process, which
finalizes on the next launch in a process whose memory is unrelated. The quantity is
**native** (`phys_footprint` / total PSS); Dart's `currentRss` is the wrong number on both
platforms and the two are not comparable, so `memory.source` puts the break on the wire.
**A five-key fault bundle on fatal crashes only** — read off the dying thread by the
Android uncaught handler; iOS attaches none, because MetricKit delivers next-launch and
this launch's state is not that crash's. `device.thermal_state` is a **normalised string**,
never the ordinal: Android's `2` is MODERATE, iOS's is serious. Everywhere here, **an
unavailable key is omitted, never sentinelled**.

`readDeviceState` is one new pull-only method on the **existing** crash channel — the
expensive surface is the three-language lockstep, not the channel string. Flat string map,
no cache, two call sites, missing plugin means empty rather than a throw.

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

The clock is **re-based**: it starts before `openUrl` (which is what connects) and stops at
headers received; `http.download_ms` carries the tail. The event is therefore emitted when the
**body ends**, not when its headers arrive — a response nobody drains is never reported, which
is already a broken consumer under `dart:io`. Phase timing comes from a **connection factory**
installed on every client, and that carries the standing hazard: a factory makes the platform
skip its own secure-socket call, so `SecurityContext`, `badCertificateCallback` and `keyLog` are
threaded through by hand or **certificate pinning breaks silently at init**. A consumer factory
is chained, never replaced. TCP/TLS cannot be split here (`ConnectionTask` has no public
constructor) and TLS is unreachable under an HTTPS proxy at any tier — omit, never zero.

PII partitions by who chose the value: the SDK redacts what it collected (`http.url` is
path-only and id-templated, folded into one `http.url_redacted` flag), caps what the developer
named (`AttributePolicy`, 50 distinct values per key per session), and hands the developer
`redactAttribute` over what they supplied. Both act on an item's **own** attributes and only on
the half the consumer chose (`EdgeEvent.consumerAttributes`) — never the context snapshot, and
never the SDK's own keys, which are unique per item by design and would be sentinelled from the
51st request. `kCappedSdkKeys` is the opt-in list for SDK keys that really are labels; it holds
`http.url` and it is opt-in rather than an exemption list so that a new emitter fails safe.

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
  `maxBatchSize`, `eventBatchSize`, `withSpan`, `withNetworkSpan` were shipped no-ops kept for that reason —
  **removed in v3.0.0**.
- **The one sanctioned exception to deprecate-don't-remove: `enableCrashReporting` and
  `enableErrorReporting`, removed outright in v3.0.0 (#72 D5).** A working switch turned into a silent
  no-op means a consumer who suppressed crash reporting begins transmitting on a `pub upgrade`. A
  `@Deprecated` lint is scrollable and an init-time `print` is invisible to a CI-only consumer; only the
  compiler is unignorable, and unignorable was the requirement. Do not generalise this — it applies where
  a removal changes *what leaves the device*, never to tidying a no-op.
- **Deprecate-in-place — names are retained, emission stops or changes.** The cycle is an annotation on
  **every** declaration naming the removal version (the clause that catches a missed field), a shipped
  release, a changelog line, and a runtime warning wherever behaviour *changes* rather than disappears.
  Every v3 deprecation names v4.0.0. Currently deprecated-in-place: `frame_render_time`
  and `screen.duration` — both stopped being emitted in v3. `user.interaction` and
  `resource_timing` are **not** deprecations: this SDK has never emitted either, so
  there is no emission to stop and no removal version to name. They are allowlist
  entries kept for family conformance, and they are recorded as **errata** (see
  `MIGRATION.md` §2) — the register for "never worked in v2", which is a different
  thing from "changed in v3".
- Terminology firewall on **new** public symbols and docs — an **anti-OpenTelemetry** rule, not an
  anti-tracing one (#56): banned are `instrumentation`/`instrument`, `OTLP`, `OpenTelemetry` and OTel
  class names (`tracer`, `SpanProcessor`, `SpanExporter`). `trace` and `span` are **permitted** where
  they name the W3C `traceparent` concept. Use `capture`, never `instrument`, for wrapping a
  consumer's client. Existing names are grandfathered; the wire (`eventName`/attr keys) is out of scope.
- The `Capture` enum is **closed at the `essential` boundary on purpose** — there is no `crash`,
  `session`, `error` or `profile` member, because an SDK reporting no crashes must never be
  indistinguishable from one configured not to. **Do not complete it for symmetry.** Adding a member
  is a decision about what a consumer may switch off, not a gap in an enumeration.
- Debug output is `print()` guarded by `config.debugMode`; the send/fail logs on `RetryTransport
  .sendImmediate` are **intentionally always printed** — leave those un-guarded. They now cover
  **fatals only**, because that is what the immediate rail carries; a non-fatal rides a batch and
  reports through the ordinary guarded path.
- Custom profile attributes are auto-prefixed with `user.`.
- **iOS required-reason APIs — the standing rule.** One is adopted only if an approved
  reason **both** fits our use **and** permits off-device transmission, and the
  declaration is made in **this package's own** `ios/Resources/PrivacyInfo.xcprivacy`,
  never inherited from a dependency's. The budget today is **zero**: the accessed-API
  array is empty, and it stays empty unless that two-part test passes. Collected data
  types are declared at the **capability ceiling** — nine, all linked to identity —
  because `device.id` rides every item and `setUserProfile()` exists; unlinked is the
  peer-conformant lie.
- `sdk.version` is a constant in `lib/src/core/sdk_version.dart`, asserted against
  `pubspec.yaml` by a test. **A release bumps both.**
- Changes visible to consumers must land in `README.md` + `CHANGELOG.md`.
