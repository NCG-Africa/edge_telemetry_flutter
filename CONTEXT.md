# EdgeTelemetry Flutter

The Flutter Real User Monitoring SDK of the Edge RUM family. It captures what an app
does at runtime — screens, requests, crashes, frames, sessions — and posts it to the
Edge collector in the family's shared custom-JSON wire format.

## Language

### Wire

**Canon**:
The family-wide contract every Edge RUM SDK emits against — the 16 event names, 4
metric names, envelope and attribute spelling. Defined here in `lib/src/core/wire_canon.dart`.
_Avoid_: schema, spec, protocol

**Batch**:
One `telemetry_batch` envelope — a timestamped array of wire items POSTed as a unit, plus the
optional hoisted context block. One batch is one session and one user.
_Avoid_: payload, bundle

**Wire item**:
A single `event` or `metric` object inside a batch. Every item rides one — the immediate
rail sends a one-item batch, never a bare item.
_Avoid_: record, message

**Event**:
A named thing that happened (`navigation`, `http.request`, `app.crash`), carrying only
string attributes.
_Avoid_: signal, log

**Metric**:
A named numeric sample (`memory_usage`, `long_task`) — an event that also carries
a top-level `value`. `frame_render_time` is retained but no longer emitted.
_Avoid_: measurement, gauge

**Allowlist**:
The canon-name gate in `Collector.add`. A batched event or metric whose name is off-canon
is dropped on the device and never reaches the wire. A hard drop, but not a silent one —
see **Dropped item**.
_Avoid_: whitelist, filter

**Dropped item**:
A wire item the SDK built and then declined to send — off-canon at the allowlist, shed by
the **governor**, capped later. Counted per session by **drop reason** and reported on
`session.finalized` (`session.dropped_item_count`, `session.dropped_reasons`), so a drop
is found by telemetry rather than by audit.
_Avoid_: discarded, filtered, rejected, lost

**Drop reason**:
The short stable slug naming why an item was dropped (`off_canon`, `tier_shed`, …). Rides
the finalize bookend verbatim; one counter, several gates.
_Avoid_: drop cause, error code

**Attribute**:
A key/value pair on a wire item. Always String-valued on the wire. Dotted for identity and
domain keys (`session.id`), unprefixed on `app.crash` (`message`, `cause`), deliberately mixed.
_Avoid_: property, field, tag

**Common attributes**:
The identity and device context from `ContextManager.snapshot()`. Merged into every wire item —
except on the batched rail once the hoist is on, where it rides the batch instead.
_Avoid_: globals, resource attributes

**Hoist**:
Moving the common attributes off each item and onto the batch, as one flat dotted block. Gated by
`kHoistBatchContext`; the immediate rail is never hoisted.
_Avoid_: lift, dedupe, compress

**Context block**:
The hoisted half — the `context` key on the envelope. Flat dotted, so the server-side merge with an
item's own bag is a plain map merge.
_Avoid_: resource, common block, header

**Mutable session counter**:
A `session.*` attribute that re-measures on every snapshot (`session.event_count`,
`session.duration_ms`, …). Cannot be batch-scoped, so under the hoist it leaves the wire on batched
items and rides only the two bookends.
_Avoid_: session stat, running total

### Rails

**Immediate rail**:
The path a **fatal** crash and the session bookends take — POSTed alone the moment it
happens, bypassing the buffer, single attempt, then persisted if it fails. Reserved for a
process that will not survive to the next flush; a non-fatal error batches.
_Avoid_: priority queue, fast path

**Batched rail**:
The default path — buffered in the Pipeline and flushed on size (30) or interval (5s).
_Avoid_: async path, queue

**Bypass**:
An item exempt from the session sampling roll (crashes, session bookends, profile updates).
Orthogonal to which rail it takes.
_Avoid_: force-send, priority

**Offline queue**:
The on-disk backlog — one JSON file per undeliverable payload, drained FIFO on the next
successful send or on startup, five files per cycle, fatal crashes first. Crash files have
their own drop-oldest cap, not an exemption; every file has an attempt ceiling. A non-fatal
error rides an ordinary batch file, because it rides an ordinary batch.
_Avoid_: cache, outbox, spool

**gzip downgrade probe**:
The one-shot self-verifying fallback: because the encoder cannot emit malformed JSON, a `400`
on a compressed body that then succeeds uncompressed **is** the capability probe. No config
flag, no version endpoint, one wasted POST per launch until the collector registers
decompression.
_Avoid_: content negotiation, feature detection, compression flag

### Correlation

**Trace**:
The `traceparent` correlation of one user intent across the client and the backend services
it calls. The client is always the root, so a trace begins where the intent begins and the
sibling SDKs and the Go services join the same id.
_Avoid_: distributed transaction, request chain, correlation

**Span**:
A referenceable interval inside a trace, carried as **an attribute set on an existing event,
never an object** — there is no span type, no span event and no span field on the wire, only
`trace.*` and `span.*` keys beside the event's own.
_Avoid_: span object, span record, tracer

**Trace id**:
32-hex, lowercase, zero-padded, guaranteed non-zero. Never carries the family
`<kind>_<epochMs>_<hex>` prefix — the two identifier namespaces coexist permanently.
_Avoid_: correlation id, request id, transaction id

**Span id**:
16-hex (`span.id`, with `parent.span.id` and `span.start_time`), minted by the single
`startChild()` call for referenceable items only — request, interaction, screen load, task
completion. A crash mints none: no duration, no children, no `traceparent`, and its action
id already joins it under its action. No error id and no client-side fingerprint either —
the server owns crash hashing.
_Avoid_: event id, request_id, error_id

**Trace root**:
The first span of a trace, minted on the device and held one-at-a-time by `TraceManager`.
Cleared on session rotation and on `paused`, and a trace never spans a session — a request
frozen in one session whose completion lands in the next is re-rooted parentless and given
an expired outcome.
_Avoid_: entry span, parent trace, root span object

**Root type**:
`trace.root_type` — which of the four things opened the trace: launch, interaction, request
or navigation. Denormalised onto every child, so "p95 HTTP latency during launch" is a
single-table scan. A navigation root is minted only when no root is live.
_Avoid_: trace kind, source, origin

**Launch root**:
The trace root covering app start. Its mark is **SDK-init-to-first-frame**, not
process-start-to-first-frame: Dart structurally cannot see process start, and no iOS
required-reason API is adopted to reach it.
_Avoid_: cold start, startup trace, process start

**Action root**:
The trace root minted at pointer-up from a completed gesture. 2 s idle / 10 s capped,
extended on child-span start and on request completion, and cleared on `paused` — which is
load-bearing, because Dart has no elapsed-realtime analogue.
_Avoid_: gesture span, interaction event, touch trace

**`rum.action.id`**:
The action root's own span id, reused as the sole join key from everything captured while
that root is open. **Not an independent identifier** — minting a second one would give an
in-action request two candidate parents.
_Avoid_: interaction id, gesture id, tap id

**Freeze**:
Copying the ambient trace and screen keys at the instant an item *describes* rather than the
instant it is emitted. Anything emitted materially later than the moment it describes
freezes: a request at call entry, a screen load, a task start, a frame window.
_Avoid_: snapshot at send, late binding, deferred context

**Ambient trace context**:
Exactly three keys — `trace.id`, `rum.action.id`, `trace.root_type` — merged into every item
from the context snapshot while a root is open, so a capture hook that never touches trace
context cannot forget it. Expiry runs in the read accessor, not the Collector: with no
timers, every expiry is somebody's read.
_Avoid_: thread local, implicit span, active span

**Trace-context ownership**:
`EdgeEvent.ownsTraceContext`, the fourth orthogonal axis beside priority, sampling bypass and
session counting. When set, the Collector strips the three ambient keys before merging the
item's own frozen copy, because **absence cannot beat presence in a spread** — an
unattributed request would otherwise be stamped with a tap that happened after it started.
_Avoid_: opt-out, no-trace flag, suppression

**Trace outcome**:
`traceparent.outcome` — five rungs recording what happened to propagation for one request
(`skipped_off_allowlist`, `adopted`, `injected_attributed`, `injected_expired`,
`injected_unattributed`), where **absence means "not traced"** and is a contract member in
its own right rather than a missing value.
_Avoid_: trace status, error code, result

**Host allowlist**:
The destinations that may receive a `traceparent` header — exact host, or a dot-anchored
suffix of at least two labels. An empty list means **dark**, and the SDK's own upload is
excluded explicitly, never by construction order.
_Avoid_: whitelist, propagation targets, trace filter

**Clock skew offset**:
`clock_skew_ms` on the envelope — the collector's clock minus the device's, taken free from
the response `Date` header and **recorded, never applied**. In-place correction destroys
debuggability and breaks idempotent replay of offline batches that arrive days late by
design.
_Avoid_: time sync, drift correction, clock fix

### Collection

**Tier**:
A collection level — an **on/off plus a shed rank**, never a sampling axis.
`essential` (crashes, session bookends, profile updates: never shed, never sampled, no
off-switch) · `standard` (default-on) · `diagnostic` (opt-in). Named `CollectionTier`.
_Avoid_: level, priority, severity, sample tier

**Capture** (the enum):
A thing a consumer may switch on or off — `Capture.http`, `Capture.swipes`. **Closed at
the `essential` boundary on purpose**: there is no `crash`, `session`, `errors` or
`profile` member, because an SDK reporting no crashes must never be indistinguishable
from one configured not to. The gap is the decision.
_Avoid_: feature, module, monitor

**Capture override**:
The `Map<Capture, bool>` that works in both directions — one map adds a diagnostic capture
and removes a standard one. Wins over the tier dial and over the deprecated v2 booleans.
_Avoid_: feature flags, toggles, enable/disable map

**Gate** (`CaptureGate`):
What a capture hook asks before it builds an attribute map. Gating happens **at the hook**;
gating at the Collector would build the map, stringify the attributes, spend the CPU and
discard the item.
_Avoid_: filter, guard, policy

**Governor**:
The per-session item counter that sheds **whole tiers** on breach — `diagnostic`, then
`standard`, never `essential` — and never individual signals. Every shed lands on the
dropped-item counter as `tier_shed`.
_Avoid_: throttle, rate limiter, sampler

**Action**:
One completed gesture — tap, long-press or swipe — as classified from the global
pointer route. It opens a trace root at pointer-up, has **no duration and no
outcome** (duration is a backend view over the root's children; outcome belongs to a
signal with a terminal moment), and emits exactly one `ui.interaction`.
_Avoid_: interaction (the event name, not the concept), gesture (the raw pointer
sequence), user journey step

**Naming call** (`trackAction`):
The one public action API. It **names the open root and emits nothing** — a helper
that emitted its own event gave adopting apps two events for one tap. Takes a name and
no attribute map, because an open map on a gesture-rate path routes around the
cardinality and PII controls.
_Avoid_: startAction, beginTransaction, trackInteraction

**Action cap**:
The per-session ceiling of 200 emitted `ui.interaction` events, enforced in the
Collector beside the allowlist. It **sheds events, never roots**: attribution survives
it and only the behavioural record thins, which is why `session.action_count` counts
roots minted rather than events emitted.
_Avoid_: rate limit, throttle, action sampling

**Seam**:
A place the SDK can see an HTTP request from. Two exist: the `dart:io` override seam
(`http_overrides`) and the client-wrapper seam. Every request names the seam that
captured it, because absence alone conflates "never measurable" with "measurable and
missing".
_Avoid_: interceptor, adapter, hook (a capture hook is a different thing)

**Seam state**:
Which seams are **live**, on every item as `sdk.http_seam_state` in four values —
`overrides`, `wrapper`, `both`, `blind`. It never says how much of the app's traffic
they see, which the SDK cannot know. `blind` is provable; the case that is not — every
request going through a bypassing client nobody wrapped — is a backend alert on
zero-request sessions, not a client-side guess.
_Avoid_: coverage, health, instrumentation state

**Fault bundle**:
The five device-state keys attached to a **fatal** crash and to nothing else —
`device.battery_level`, `device.battery_charging`, `device.power_save_mode`,
`device.thermal_state`, `device.orientation`. Read off the dying thread, where the binder
calls are free. A key the platform cannot answer is **omitted**, never sentinelled.
_Avoid_: device health snapshot, device state event, health sample

**Memory bookend**:
One `memory_usage` metric when the session opens and one when the app is backgrounded —
two items, where v2 sampled sixty. The quantity is native (`phys_footprint` on iOS, total
PSS on Android) and `memory.source` names it on the wire.
_Avoid_: memory poll, memory sample, memory tick

**Captured client**:
A `package:http` client handed to `captureClient` and returned as a client. The same
type in and out is what lets an already-captured client, a pre-init call, a disabled
capture and an `IOClient` the override already sees all come back unchanged.
_Avoid_: instrumented client, wrapped client, proxy client

**Fused connect**:
DNS + TCP + TLS as one number (`http.connect_ms`). Fused because splitting DNS means
resolving by hand, and resolving by hand means connecting to one address instead of
every address the platform would try. Split only at `diagnostic`, and only as far as
`http.dns_ms` — TCP and TLS are unreachable at this seam.
_Avoid_: handshake time, setup time, TTFB

**Templated path**:
A URL path whose id segments — all-digits, a UUID, or 20+ hex characters — have become
`{id}`. An **exact enumerable rule**, not a heuristic, so a backend reading the rows can
reproduce it. Its real job is keeping a REST app under the cardinality cap.
_Avoid_: normalised URL, sanitised URL, route pattern

**Cardinality cap**:
50 distinct values per attribute key per session; the 51st and everything after becomes
`__over_cardinality__` and is counted on `session.cardinality_capped_count`. A capped
value is **not** a dropped item and never touches the dropped-item counter. It applies
to consumer-named keys plus `kCappedSdkKeys` — an **opt-in** list, because most of what
the SDK mints per item is unique by design.
_Avoid_: dimension limit, tag limit, truncation

**Redaction hook** (`redactAttribute`):
The consumer's one callback at the wire choke point, over the attributes the consumer
themselves passed in (`EdgeEvent.consumerAttributes`). Never the context snapshot (30
callbacks per item on the UI isolate for values the SDK chose itself) and never the
SDK's own item keys.
_Avoid_: scrubber, filter, sanitizer, processor

**Window** (a frame window):
One **screen segment** of accumulated frame timings — opened at the first frame after
the last one closed, closed by a screen change or a 10 s cap, whichever comes first,
both checked inside the frame callback. It is the subject of a `frame.summary`, and
it is **not an action**: a window spans several of them, which is why the event
carries no trace or action id.
_Avoid_: bucket, interval, sample period, frame batch

**Slow frame** / **Frozen frame**:
A frame whose **total span** (vsync start → raster finish, never build + raster, which
are pipelined) exceeds 16 ms / 700 ms. Frozen is a subset of slow. Both thresholds are
**fixed absolutes** and never derived from the refresh rate — the rate is recorded, not
applied, so the count means one quantity across every device and every sibling SDK.
_Avoid_: janky frame, dropped frame, ANR frame, budget overrun

**Eligibility floor**:
The rule that a window with **zero slow frames is discarded** rather than emitted. It is
what keeps `screen.name` pointing at a screen that actually stuttered. Its cost is that
`frame.total_frames` is a biased denominator — never a fleet rate.
_Avoid_: threshold, filter, minimum

**Reservoir** (the frame reservoir):
The **keep-worst-two** hold over closed windows, ranked on `(frozen frames, slow frames,
worst frame)` — **absolute counts, never a rate**, or a five-frame window would evict a
six-hundred-frame one. Survivors are emitted at pause and before `session.finalized`,
and an emitted survivor **stays as a ranking incumbent** for the rest of the session, so
a resumed session neither re-sends it nor starts ranking from empty.
_Avoid_: buffer, cache, sample, top-N queue

**Long task**:
The `long_task` metric, **redefined to frozen frames only** — name and slot kept, population
changed. At v2's per-frame threshold its cap was exhausted by the first two-second stall,
reproducing one tier down the start-of-session bias the reservoir exists to avoid.
_Avoid_: stall, hang, blocked frame

**Honesty key**:
An attribute whose only job is to stop a derived value from reading as a measured one, or a
capability gap from reading as a backend bug. Nine on the wire today: `ui.name_source`,
`screen.load.source`, `error.category_source`, `http.url_redacted`, `http.response_size_source`,
`http.seam`, `sdk.http_seam_state`, `task.abandon_source`, `memory.source`.
_Avoid_: metadata, provenance, quality flag, debug attribute

### Screen load

**Screen visit**:
One entry onto a route, identified by a `screen.id` minted on **every** entry — so a
back-navigation is a new visit. Deliberately **not** a span: making it one would give an
in-tap request two candidate parents.
_Avoid_: page view, screen session, route span

**`screen.id`**:
16-hex and session-scoped, so it needs no family prefix. Owned by `SessionManager` because
it expires with the session, which is also why a screen change has no code path to the trace
root at all.
_Avoid_: route id, page id, view id

**TTFF**:
Time to first frame (`screen.load.first_frame_ms`) — the first post-frame callback after the
route push, with the navigation transition **deliberately excluded**, so "your screen is
slow" is never confused with "your transition is 300 ms".
_Avoid_: first paint, render start, time to render

**Settled**:
The second and last screen-load mark (`screen.load.settled_ms`): first frame reached, no
in-flight request carrying this screen id, and a 500 ms quiet window. **Inferred by
default** — an explicit `reportScreenSettled` overrides it — which inverts the industry
manual-first default, because the data is silently missing wherever consumers do not call.
_Avoid_: ready, loaded, complete, interactive

**Settled source**:
`screen.load.source` (`inferred` / `reported`), on every event, so an inferred number and a
measured one are never averaged as though they were the same measurement. There is no third
value: absence would be the ambiguity the key exists to remove.
_Avoid_: method, mode, origin

**TTI**:
Time-to-interactive — **deliberately not adopted**, rejected with a reason rather than
deferred: it is a web main-thread-quiet metric, while a Flutter route's gesture arena is live
at frame one, so the mark would be a constant equal to first frame. Render-complete falls to
the same class of reason — nothing completes after first raster.
_Avoid_: interactive time, usable time, time to usable

**Screen-load outcome**:
`screen.load.outcome` — the four terminals one screen entry can reach (`settled`,
`abandoned`, `deadline_exceeded`, `backgrounded`), emitted once at the first of them.
Non-settled paths carry no duration of their own, so user behaviour never poisons the p95 the
metric exists to serve. The 10-second deadline is pinned to the action root's cap, not chosen.
_Avoid_: status, result, error

### Experience

**Task**:
A developer-declared multi-screen journey — start, complete, fail, string-keyed, no attribute
map — because a four-route transfer is the unit the product cares about, not the individual
screens. Start costs no wire item; a duplicate start supersedes. The developer is the **only
possible source** of this signal, so the category's coverage is conditional, in those words.
_Avoid_: flow, funnel, transaction, journey

**Task outcome**:
`task.outcome` — `completed`, `failed` or `abandoned`, emitted once at the terminal.
Abandonment is triggered **only** by session finalize: navigation-away would abandon every
task in a four-route flow, and backgrounding would report reading an OTP as a failure.
Time-on-task reuses `span.duration_ms` and measures start → last activity, never → finalize
wall-clock.
_Avoid_: status, state, verdict

**Abandon source**:
`task.abandon_source` — the honesty key stating that a crash is indistinguishable from an OS
kill here, because the backdated finalize, and therefore the abandoned task, is emitted
before native crashes are drained. It states the gap rather than hiding it.
_Avoid_: reason, cause, trigger

**Apdex target**:
One of three independent **query-time** thresholds — screen load, request duration, span
duration — because one threshold satisfying a screen load, a round-trip and a four-screen
banking flow is not a threshold but an average of three unrelated product judgements. Apdex
ships zero events, zero attributes and zero bytes; the client never bands, so history can be
re-banded when the product's definition of slow changes.
_Avoid_: SLA, threshold config, slow flag, satisfaction score

### Session

**Session**:
One continuous stretch of app use, identified by a `session.id` and bracketed by a
`session.started` and a `session.finalized` event.
_Avoid_: visit, run

**Rotation**:
Ending the current session and starting a new one after 30 minutes of inactivity. Evaluated
lazily on the next event or on resume — never on a timer.
_Avoid_: expiry, refresh

**Kill recovery**:
Finalizing, on the next launch, a session that the OS killed — backdated to its last
recorded activity.
_Avoid_: resurrection, replay

**Journey summary**:
The counts and ordered screen path carried on `session.finalized` (`session.screen_journey`,
capped at 20 hops), plus the final screen's dwell (`session.last_screen_duration_ms`) —
silently lost on every session since v2, and recovered here at zero items.
_Avoid_: session stats, funnel

### Crash

**Crash**:
Any captured failure, Dart or native, emitted as the `app.crash` event. Dart errors are
non-fatal crashes (`is_fatal:"false"`); the app survived them, so they ride the batch rail.
_Avoid_: error report, exception event

**Cause**:
The crash taxonomy — `Error` (all Dart entry points), `NativeCrash`, `ANR`, `Hang`. The
specific Dart handler goes in the secondary `crash.source`, never in `cause`. It is **not**
the error category: the sibling's `cause` is free text and this one is an enum, both
shipped, so the taxonomy got its own key instead.
_Avoid_: kind, category, severity

**Error category**:
The non-fatal taxonomy on its own dotted key, `error.category` —
`network`/`timeout`/`auth`/`parse`/`storage`/`business`/`unknown`, with
`error.category_source` saying whether the SDK inferred it from the error's exact type or
the developer declared it. `auth` and `business` are declared-only: no platform type means
either. Named `ErrorCategory`.
_Avoid_: error type, error kind, severity, cause

**Handled**:
Whether the app kept running because someone caught the error — `"true"` for `trackError`
and the SDK's own self-diagnostics, `"false"` for the three auto-installed handlers
(`flutter_error`, `platform_dispatcher`, `isolate`) and every native crash. A string,
matching the shipped `is_fatal`.
_Avoid_: caught, recovered, is_handled

**Drain**:
The one-shot pull of crashes the native plugin recorded before the process died, called
once on init over the `edge_telemetry/native_crash` channel. A dying process cannot call
Dart, so next-launch pull is the only model.
_Avoid_: flush, fetch

**Native capture tier**:
Honest per-device native coverage, reported as `sdk.native_capture_tier`: `full` on Android
API 30+, `jvm_only` below it. Unrelated to a collection **Tier** — one word, two things.
_Avoid_: capability, support level, collection tier

**Breadcrumb**:
A short trail entry (navigation, request, lifecycle, or host-added) kept in a 50-slot ring
and attached to a crash as context. A fatal ships all 50; a non-fatal ships the newest 10.
Never sent on ordinary events.
_Avoid_: trail, log line

### Identity

**Device ID**:
`device_<epochMs>_<16hex>_<platform>`, kept in secure storage — on iOS it survives
reinstall, on Android it does not. Must appear in every batch or the collector rejects it.
_Avoid_: install ID, client ID

**User ID**:
`user_<epochMs>_<16hex>` — SDK-owned and anonymous. Setting a profile attaches `user.*`
attributes but never changes the ID, so anonymous and identified activity stitch to one timeline.
_Avoid_: account ID, customer ID

**Platform vs SDK platform**:
`device.platform` is the real OS (`ios`/`android`) so Flutter devices group with native ones;
`sdk.platform` (`flutter-ios`/`flutter-android`) is the only place "built with Flutter" appears.
_Avoid_: os, runtime

### Migration

**Deprecate-in-place**:
The no-renames rule made operational: a name is retained on the wire and in the API while its
emission or meaning changes, with an annotation on **every** declaration naming the removal
version, a shipped release, a changelog line, and a runtime warning wherever behaviour
*changes* rather than disappears. Every v3 deprecation names v4.0.0.
_Avoid_: rename, alias, soft delete, sunset

**Errata register**:
The dated list of things that never worked as documented, kept on its own line in
`MIGRATION.md` and never folded into the break list. "Removed in v3" is a change a reader
acts on; "never worked in v2" is a belief they need corrected about telemetry they have
already shipped and drawn conclusions from.
_Avoid_: known issues, bugfixes, changelog notes

### Structure

**Facade**:
The `EdgeTelemetry` singleton — the entire public surface, delegating to wiring it owns.
_Avoid_: client, manager, API object

**Collector**:
The per-item gatekeeper between capture and transport: sample gate, context merge,
breadcrumb attach, allowlist, counters.
_Avoid_: processor, middleware

**Pipeline**:
The buffer that batches items and hands finished batches to transport.
_Avoid_: queue, dispatcher

**Capture hook**:
A unit that listens to one Flutter source (requests, navigation, lifecycle, frames,
connectivity, pointers) and feeds events in. Each returns a dispose handle, and each is
where its tier gates — before the attribute map is built.
_Avoid_: monitor, tracker, listener, instrumentation
