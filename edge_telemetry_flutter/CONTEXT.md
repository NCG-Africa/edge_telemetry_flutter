# EdgeTelemetry Flutter

The Flutter Real User Monitoring SDK of the Edge RUM family. It captures what an app
does at runtime — screens, requests, crashes, frames, sessions — and posts it to the
Edge collector in the family's shared custom-JSON wire format.

## Language

### Wire

**Canon**:
The family-wide contract every Edge RUM SDK emits against — the 12 event names, 4
metric names, envelope and attribute spelling. Defined here in `lib/src/core/wire_canon.dart`.
_Avoid_: schema, spec, protocol

**Batch**:
One `telemetry_batch` envelope — a timestamped array of wire items POSTed as a unit.
_Avoid_: payload, bundle

**Wire item**:
A single `event` or `metric` object inside a batch, or POSTed alone on the immediate rail.
_Avoid_: record, message

**Event**:
A named thing that happened (`navigation`, `http.request`, `app.crash`), carrying only
string attributes.
_Avoid_: signal, log

**Metric**:
A named numeric sample (`frame_render_time`, `memory_usage`) — an event that also carries
a top-level `value`.
_Avoid_: measurement, gauge

**Allowlist**:
The canon-name gate in `Collector.add`. A batched event or metric whose name is off-canon
is dropped on the device and never reaches the wire.
_Avoid_: whitelist, filter

**Attribute**:
A key/value pair on a wire item. Always String-valued on the wire. Dotted for identity and
domain keys (`session.id`), unprefixed on `app.crash` (`message`, `cause`), deliberately mixed.
_Avoid_: property, field, tag

**Common attributes**:
The identity and device context merged into every wire item from `ContextManager.snapshot()`.
_Avoid_: globals, resource attributes

### Rails

**Immediate rail**:
The path a crash takes — POSTed alone the moment it happens, bypassing the buffer, single
attempt, then persisted if it fails.
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
successful send or on startup. Crash files are exempt from its drop-oldest cap.
_Avoid_: cache, outbox, spool

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
capped at 20 hops).
_Avoid_: session stats, funnel

### Crash

**Crash**:
Any captured failure, Dart or native, emitted as the `app.crash` event. Dart errors are
non-fatal crashes (`is_fatal:"false"`); the app survived them.
_Avoid_: error report, exception event

**Cause**:
The crash taxonomy — `Error` (all Dart entry points), `NativeCrash`, `ANR`, `Hang`. The
specific Dart handler goes in the secondary `crash.source`, never in `cause`.
_Avoid_: kind, category, severity

**Drain**:
The one-shot pull of crashes the native plugin recorded before the process died, called
once on init over the `edge_telemetry/native_crash` channel. A dying process cannot call
Dart, so next-launch pull is the only model.
_Avoid_: flush, fetch

**Capture tier**:
Honest per-device native coverage, reported as `sdk.native_capture_tier`: `full` on Android
API 30+, `jvm_only` below it.
_Avoid_: capability, support level

**Breadcrumb**:
A short trail entry (navigation, request, lifecycle, or host-added) kept in a 20-slot ring
and attached to a crash as context. Never sent on ordinary events.
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
connectivity) and feeds events in. Each returns a dispose handle.
_Avoid_: monitor, tracker, listener, instrumentation
