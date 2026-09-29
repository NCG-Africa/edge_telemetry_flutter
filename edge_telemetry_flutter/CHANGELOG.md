# Changelog

## [Unreleased]

### Added

- **HTTP request timing is re-based, and the phases are measured.**
  `http.duration_ms` now runs from **before the call to headers received** — v2
  started its clock after the connection was already established, so it measured
  neither connection setup nor content download and under-reported a cold request
  by 3.5-4x (509 ms connect, 149 ms reported, 10 ms download, measured).
  `http.download_ms` carries the tail separately; total wall clock is the sum,
  derivable, never guessed. The default tier also gets `http.connect_ms` (DNS +
  TCP + TLS **fused**) and a `http.connection_reused` flag **measured** by joining
  the request's local port to the connection's own connect record. Time to first
  byte is derived by subtraction and never emitted.
- **`http.dns_ms`, `http.queue_ms` and `http.redirect_count` at the `diagnostic`
  tier**, behind the new `Capture.httpRequestPhases`. Splitting DNS out costs a
  resolver call the platform does not make and gives up its try-every-address
  fallback, which is exactly why the fused number is what every default build
  gets. TCP and TLS cannot be separated at this seam at all — the platform's
  `ConnectionTask` has no public constructor, so a connection factory cannot hand
  back a task wrapped around a socket it upgraded itself; their sum is
  `connect - dns` and neither is guessed. Under an HTTPS proxy the handshake
  happens inside the platform's CONNECT tunnel, so TLS time is unreachable at any
  tier.
- **`http.response_size_source`** — `content_length` when the server declared one,
  else `decoded_bytes`. The two were measured **9x apart on one response**, and the
  platform reports no length at all on chunked encoding, i.e. on most modern JSON
  APIs. An unknown size is omitted, never sent as a false zero.
- **`http.seam`** on every request, naming the capture seam that saw it. Absence
  alone conflates "never measurable" with "measurable and missing" and leaves a
  backend's connect-time denominator wrong.
- **`EdgeTelemetry.instance.captureClient(client)` — capture a `package:http`
  client that `HttpOverrides` cannot see.** `HttpOverrides.global` reaches every
  `dart:io` socket and nothing else, so an app on `cupertino_http` (NSURLSession)
  or `cronet_http` (Cronet) is not *thinly* covered — it is **totally invisible**,
  and because the same seam carries `traceparent`, every one of its requests is
  also a severed distributed trace. **Client in, same type out**: an already
  captured client, a call made before `initialize()`, and a build with
  `Capture.http` off all return the argument itself, so double capture is designed
  out at construction rather than documented around. Freeze and inject collapse
  into **one instant** on this seam — `send` is entered synchronously and the
  headers precede it — which makes `injected_expired` unreachable here. Rows carry
  `http.seam: http_client` and omit `http.connect_ms` / `http.dns_ms` /
  `http.queue_ms` / `http.connection_reused`: the platform client below the wrapper
  owns the connection pool. gRPC, HTTP/2 and `http2_adapter` stay out of scope — a
  protocol gap, not a wrapper gap. Adds `package:http` as a direct dependency:
  Dart-team owned, pure Dart, and already in the pubspec of every consumer who can
  hit this, since `cupertino_http` and `cronet_http` *are* `package:http`
  implementations.
- **`sdk.http_seam_state` on every item — four values, one of them provable.**
  `overrides`, `wrapper`, `both`, `blind`. It says which seams are **live**, and
  pointedly not how much of your traffic they see; a client the SDK was never
  handed is indistinguishable from one that is never used. `blind` is provable: the
  `dart:io` global is no longer ours and nothing was wrapped. It is evaluated at
  every snapshot rather than latched at install, because a consumer can sever the
  override at any instant and nothing notifies the SDK. The one undetectable case —
  capture healthy, every request going through a bypassing client nobody wrapped —
  is **not** papered over client-side; it is a backend alert on sessions that
  finalize with `session.http_request_count == 0` while the seam state says a seam
  was live.
- **A connection that never opened is now a measured row.** A refused connection,
  a DNS failure or no network at all emits `http.request` with status 0 and
  `http.error`; v2 started measuring only once the connection had succeeded, so
  the whole offline case was invisible.
- **`redactAttribute`** — one redaction hook, run at the single wire choke point
  over each item's **own** attributes. Return the value to send, or null to drop
  the key. It never sees the ~30-key context snapshot (that would be 30 consumer
  callbacks per item on the UI isolate for values the SDK chose itself), and it
  never sees the session bookends, whose attributes are the session's identity.
- **A per-key cardinality cap of 50 distinct values per session.** The 51st
  distinct value for a key and everything after it becomes
  `__over_cardinality__`, counted on the new `session.cardinality_capped_count`
  — a counter of its own, because a replaced value is not a dropped item and must
  not corrupt `session.dropped_item_count`.

- **Distributed tracing: requests to hosts you list carry a W3C `traceparent`.**
  New `traceHostAllowlist` config — matched as an exact host or a dot-anchored
  suffix of at least two labels, and **empty (the default) means dark**: no
  header is injected anywhere until a host is listed, because the header carries
  internal trace topology. `traceparent` only — no `tracestate`, no B3 — and
  spans stay attributes on existing events. The carrier is frozen at the
  **synchronous call instant**, before the connection is attempted (a cold
  connect measured 509 ms), and the header and the `http.request` describing it
  are built from that one frozen copy, so the wire and the row cannot disagree.
  `http.request` gains the frozen trace keys plus `span.start_time`, and
  `span.duration_ms` on the rows that are spans under an action — a request that
  re-rooted itself is a root, and a root's duration is derived server-side from
  its children.
- **`traceparent.outcome` on `http.request`, five values, and absence means
  "not traced".** `skipped_off_allowlist` (host not listed — ids still stamped
  locally, no header sent), `adopted` (you had set your own `traceparent`; it is
  left untouched, its ids mirrored, and the request stays joined to your tap
  through `rum.action.id`), `injected_attributed`, `injected_expired` (the action
  aged out, or the session rotated while the request was in flight — re-rooted
  parentless) and `injected_unattributed` (nothing was in progress). The SDK's
  own telemetry upload carries no outcome key and emits no `http.request` at
  all: it is excluded **explicitly** rather than by construction order, because
  capturing it is unbounded amplification.
- **Known limitation, declined and documented: redirects leak the header.**
  `dart:io` copies request headers onto a redirect target inside `close()`,
  below this SDK's wrapper, so a 302 from a listed host to an unlisted one
  carries the `traceparent` with it. Closing it would mean the SDK taking over
  redirect semantics to serve a telemetry concern. Asserted as a known
  limitation in the seam test rather than silently tolerated.
- **Clock skew is recorded, never corrected.** Successful POSTs read the
  collector's `Date` response header and ship the offset as `clock_skew_ms` on
  the batch envelope, so a session can be shifted onto server time at query
  time. Client timestamps are never rewritten — that would destroy debuggability
  and break idempotent replay of offline batches, which by design arrive hours
  or days late.

- **The correlation spine: trace context now rides the context snapshot.** An
  open trace root (one of `launch`, `interaction`, `request`, `navigation`) puts
  exactly three keys — `trace.id`, `rum.action.id`, `trace.root_type` — on every
  item enriched while it is open, so crashes, frame aggregates and device
  readings are attributed without any capture site touching trace context. A
  referenceable item instead makes one call that freezes its own copy and mints
  its child `span.id` / `parent.span.id`; the event marks itself as owning that
  context and the ambient keys are stripped rather than spread underneath it, so
  a request that started before the user touched the screen can never be
  attributed to the tap that followed it. A request's own `span.id` is the
  request id — there is no `request_id` and no `error_id`.
- **User actions are captured automatically, and `trackAction(name)` names
  them.** A global pointer route classifies every completed gesture — tap,
  long-press, swipe — against the framework's own touch slop, long-press
  timeout and minimum fling velocity, mints an `interaction` trace root at
  pointer-up and emits one `ui.interaction`. Nothing to annotate: an app that
  never calls a telemetry API still gets action attribution on its requests,
  crashes and frames. A scroll coming to a stop deliberately mints nothing.
  `EdgeTelemetry.instance.trackAction('transfer')` **names the open root and
  emits nothing of its own**, so one tap is one event with a real name rather
  than two events across two schemas; call it synchronously from the handler.
  It takes no attribute map (`trackEvent` already does) and the action carries
  no duration and no outcome, so there is no pair to close and nothing to leak.
  Swipe *emission* is diagnostic-tier and off by default; the root is minted
  either way, so attribution survives the tier.
- **`session.action_count`** — trace roots minted this session, including the
  ones whose event the per-session cap of 200 `ui.interaction` events shed. A
  busy session therefore reads as "400 actions, 200 recorded" rather than as a
  quiet one, and the shed lands on `session.dropped_reasons` as `action_cap`.
- **A `navigation` root is minted only when no root is live**, which attributes
  a deep link or a notification-opened screen without ever stealing the root
  from the tap that pushed the route.
- **`screen.id`** — 16 hex characters, minted on every screen entry, so a
  back-navigation to the same route is a new, identifiable visit rather than an
  ambiguous replay of an earlier one. Session-scoped and reset on rotation.
- The root is lazily expired (2 s idle, 10 s cap) and cleared on session
  rotation and on `AppLifecycleState.paused` — no timer, in keeping with the
  rest of the SDK. A trace never spans a session.

- **Batch-level context hoist, behind an internal flip that ships off.** About
  81% of every v2 item is repeated context. The `telemetry_batch` envelope can
  now carry one flat dotted `context` block — static device/app/SDK identity,
  `user.id`, session identity, and the two batch-scoped live values
  (`network.type`, `device.platform_brightness`) — instead of a copy per item,
  taking a typical item from 1,467 B to 308 B. A session or user change forces a
  flush, so one batch is structurally one session and one user; the mutable
  session counters leave the wire on batched items and ride only the two session
  bookends. **Nothing changes for consumers in this release:** the flip is a
  compile-time constant, never a config field, and it stays off until the
  processor-side merge lands — an unmerged processor drops the unknown block and
  every session arrives with an empty `session.id`, which is corruption rather
  than a dead letter.
- **Four new canon event names** — `ui.interaction`, `frame.summary`,
  `screen.load`, `task.complete`. The wire allowlist now holds 16 event names
  and 4 metric names; emitters land in their own releases.
- **The allowlist drop is visible.** Off-canon items are still dropped on the
  device (the allowlist is the one guard against an unbudgeted emitter), but the
  drop now prints under `debugMode: true` and increments a session-scoped
  counter that ships on the session's closing event as
  `session.dropped_item_count` and `session.dropped_reasons` (e.g.
  `off_canon=7`). Seven of v2.0.0's own internal emissions were dropped on every
  device for the whole release and were found by audit rather than by telemetry;
  this is the fix for the silence, not for the drop.

- **gzip on every POST**, with a self-verifying one-shot downgrade: a 400 on a
  compressed body is re-POSTed once uncompressed, and compression stays off for
  the launch only if that succeeds. No config flag and no version endpoint — the
  probe *is* the capability check, and it costs at most one wasted POST per
  launch until the collector registers decompression.

### Changed

- **Every HTTP duration now comes off a monotonic `Stopwatch`** rather than two
  wall-clock reads. A request spanning an NTP correction or a user clock change
  could report a negative duration. Timestamps stay absolute UTC, because
  `span.start_time` must be absolute to join a client span to a server one.

- **`http.url` defaults to path-only, with an honesty flag.** Scheme, host and
  path; no query string, no fragment, no userinfo. v2 shipped the **full query
  string** on the highest-volume event in the system (~40 times per session),
  eleven lines from the breadcrumb path that strips it *because* no PII should
  ride the crash ring — the precedent was not missing, it was inverted. Path
  segments that are all digits, a UUID, or 20+ hex characters become `{id}`, by
  an exact enumerable rule rather than a heuristic no backend could reproduce.
  Both facts fold into one `http.url_redacted` flag rather than minting a second
  key. Turn `Capture.httpQueryString` on for the full URL at the `diagnostic`
  tier.
- **`http.success` conforms to 2xx only** (v2 counted 3xx as a success too). The
  platform follows redirects by default, so almost no row changes while the
  family's cross-SDK error rate stops disagreeing with itself on a shipped key.
  `HttpRequestTelemetry.isSuccess` changes with it.
- **HTTP capture installs a connection factory**, which is the only way connect
  time and the reuse flag are reachable. Installing one makes the platform take a
  branch that never reaches its own secure-socket call, so the SDK threads your
  `SecurityContext`, `badCertificateCallback` and `keyLog` through it **by hand**
  — without that, certificate pinning would break silently at init and the app
  would keep working against any certificate. A `connectionFactory` you set
  yourself is chained, not replaced.
- **`http.request` is emitted when the response body ends, not when its headers
  arrive**, which is what makes the download tail and the decoded-byte count
  measurable. A response whose body is never read is therefore never reported;
  `dart:io` requires the body be drained or the connection stalls, so every real
  client already drains it.

- **A 4xx is dropped, never retried and never queued**, and counted on the
  existing session counter by status (`http_400=1`). A payload the collector
  refuses will be refused every time; queueing it only bought an unbounded
  re-POST.
- **Crash payloads lose their queue exemption.** They now have their own
  generous cap (50 files, drop-oldest) plus a five-attempt per-file ceiling,
  with every drop counted (`queue_overflow`, `queue_attempts_exhausted`, and
  `queue_corrupt` for an unreadable file). An attempt is spent only when the
  collector was reachable — a drain cycle that finds the device offline is
  abandoned untouched, so a week with no network cannot delete a crash.
  "A crash is never dropped" is exactly what made the re-POST amplification
  unbounded. Crashes drain ahead of batches, and a drain cycle is paced at five
  files on the existing successful-send trigger — no new timer.
- **Collection is now two fields: `tier` and `captureOverrides`.**
  `tier: CollectionTier.essential | standard | diagnostic` is the dial;
  `captureOverrides: Map<Capture, bool>` is the scalpel and works in both
  directions (`{Capture.swipes: true}` adds, `{Capture.http: false}` removes).
  A tier is an on/off plus a shed rank, never a sampling axis — `sampleRate`
  remains one roll per session.
- **A budget governor sheds whole tiers** — `diagnostic`, then `standard`,
  never `essential` — once a session crosses its item ceiling, and counts every
  shed on the existing `session.dropped_item_count` /
  `session.dropped_reasons` (`tier_shed=N`) that ships on the session's closing
  event.
- **`app_lifecycle` now emits `paused` and `resumed` only, by default.**
  `inactive`, `hidden` and `detached` move to `Capture.lifecycleTransitions`
  (`diagnostic`, opt-in). The framework synthesizes all three on every
  backgrounding round-trip, so v2 shipped six lifecycle items per round-trip
  where the budget assumed two, and nothing read the extra four. Restore them
  with `captureOverrides: {Capture.lifecycleTransitions: true}`. The
  lifecycle→session bridge is unchanged and unconditional — only the event is
  tiered.
- **`trackEvent` / `trackMetric` take `Map<String, Object?>?`** instead of
  `dynamic`. Values are stringified as before, so `{'count': 3, 'ok': true}`
  keeps compiling and the bytes on the wire are unchanged. The `toJson()`
  reflection fallback is deleted — passing an arbitrary object is no longer a
  supported attribute shape.

### Fixed

- **Crashes are delivered.** The immediate rail POSTed a bare wire item with no
  `events` array; the collector answered 400, and the payload parked in a
  cap-exempt file that was re-POSTed after every successful batch for the life
  of the install. **No consumer has received a crash since v2.0.0** — externally
  indistinguishable from an app that does not crash, which is why the bug
  survived a release. The rail now sends a one-item `telemetry_batch` envelope,
  and a payload stored bare by an earlier version is re-wrapped when it drains,
  so the backlog accumulated since v2.0.0 arrives as soon as v3 runs once.

### Removed

- **`enableCrashReporting` and `enableErrorReporting` are removed outright** —
  from `initialize()` and from `TelemetryConfig`. This is a deliberate hard
  compile break, not a silent no-op: a consumer who had deliberately suppressed
  crash reporting must not begin transmitting because of a `pub upgrade`. Crash
  and error capture are unconditional in v3, and `Capture` has no member for
  either — an SDK reporting no crashes must never be indistinguishable from one
  configured not to. If the concern is volume, use
  `tier: CollectionTier.essential`; if it is privacy, note that `app.crash`
  carries no arbitrary consumer attributes.
- `initialize(useJsonFormat:)` and `TelemetryConfig.useJsonFormat` — the SDK has
  been custom-JSON only since v2.0.0. **The `TelemetryConfig` field never
  carried a `@Deprecated` annotation**, so a consumer who constructed the class
  by hand gets a compile error with no deprecation cycle behind it. Named here
  rather than left to the compiler.
- `initialize(batchTimeout:/maxBatchSize:/eventBatchSize:)` and the matching
  `TelemetryConfig` fields — use `flushIntervalMs` and `batchSize`.
- `withSpan()` / `withNetworkSpan()` — OTel-era no-ops that recorded nothing.

### Deprecated

Deprecated-in-place, still honoured as a fallback (the new key always wins), and
**removed in v4.0.0** — annotated on the facade parameter *and* the
`TelemetryConfig` field:

| v2 | v3 |
|---|---|
| `enableHttpMonitoring: false` | `captureOverrides: {Capture.http: false}` |
| `enableNavigationTracking: false` | `captureOverrides: {Capture.navigation: false}` |
| `enablePerformanceMonitoring: false` | `captureOverrides: {Capture.frames: false, Capture.health: false}` |
| `enableNetworkMonitoring: false` | `captureOverrides: {Capture.connectivity: false}` |
| `captureAccessibilityContext: true` | `captureOverrides: {Capture.accessibilityContext: true}` |

`enableLocalReporting` is **not** deprecated: it gates a sink (the on-device
report store), not a capture, and never touches the wire.

### Errata

- **`enableErrorReporting` has had no effect since v2.0.0.** Error capture has
  been unconditional since that release — `initialize()` never exposed the
  parameter and hardcoded the config field to `true`. This was not disclosed at
  the time.
- **`TelemetryConfig.hasAutomaticMonitoring` could never return `false`** in
  v2.0.0, because it OR'd `enableErrorReporting`, which was always `true`. It
  now reports whether any capture is actually enabled.

## [2.0.0] - 2026-07-13

**The wire changed — your code mostly didn't.** This is the atomic v2.0.0:
OpenTelemetry is gone, the wire is aligned to the Edge RUM family canon, native
crash capture (iOS + Android) is in, and the 1251-line barrel god-object is
split into the family's 5-layer architecture. For the common consumer the
upgrade is a two-line checklist, not an investigation.

### 🧭 Migrating from 1.x — the whole checklist

1. **Bump the iOS Podfile floor to 14** (`platform :ios, '14.0'`). Required by
   MetricKit native crash capture — this is the one guaranteed build break.
2. **Pass `apiKey:` to `initialize()`** — the collector now authenticates via an
   `X-API-Key` header (omit it and the collector 401s). `endpoint` is now a
   **base URL**; the SDK posts to `<endpoint>/collector/telemetry`.
3. **Delete 4 removed symbols if you used them** (all OTel-leak / long-deprecated
   — see 💥 below): `startSpan()`, `endSpan()`, `activeScreenSpans`,
   `initialize(runAppCallback:)`. Crash handlers now install automatically.

Everything else compiles unchanged. `withSpan` / `withNetworkSpan` /
`useJsonFormat:` are kept as deprecated no-ops (removed in v3.0.0); your one
`navigationObserver` wiring line is untouched. **What you gain:** native crash
visibility, family-aligned dashboards (Flutter sessions render beside native
ones), a real 5-second flush (was a latent 5-*minute* default), offline
durability for all telemetry (was crash-only), and no dead OTel weight.

> **Ship gate.** v2.0.0's wire + backend-accommodation asks require
> **backend-team sign-off** (spec #15 §10 / #30) — engineering-green does not
> ship alone. On-device native-crash e2e is verified on a device matrix
> post-merge (#29 deviation). Both are tracked outside this changelog.

### 💥 Breaking (source break on upgrade)
- **REMOVED**: `startSpan()` / `endSpan()` — returned/consumed the deleted OTel
  `Span` type.
- **REMOVED**: `EdgeNavigationObserver.activeScreenSpans` and its
  `registerScreenSpan()` / `onSpanStart` / `onSpanEnd` constructor params.
- **REMOVED**: `initialize(runAppCallback:)` — deprecated in 1.5.2 with a
  stated "removed in v2.0.0"; crash handlers install automatically.

### ⚠️ Deprecated (now no-ops, removed in v3.0.0)
- `initialize(useJsonFormat:)` — ignored; the SDK is custom-JSON only.
- `withSpan()` / `withNetworkSpan()` — just run your function, record nothing.
- Each warns once per process when `debugMode` is on.

### 🆔 Identity contract (Phase 3)
- **CHANGED**: device/session/user IDs now carry 64-bit entropy via
  `Random.secure()` in the canon family format —
  `device_<epochMs>_<16hex>_<platform>`, `session_<epochMs>_<16hex>_<platform>`,
  `user_<epochMs>_<16hex>`. Was 8-char (device/user) / bare-16 (session).
- **CHANGED**: `device.id` is now stored in `flutter_secure_storage` (iOS
  Keychain survives reinstall) instead of `SharedPreferences`. New dependency:
  `flutter_secure_storage: ^9.2.4`.
- **ADDED**: `sdk.platform` attribute = `flutter-<os>`; `device.platform`
  remains the real OS.
- The device-ID validator accepts BOTH the legacy 8-alnum and new 16-hex random
  widths, so IDs minted before this release upgrade in place. `user.id` stays
  stable across `setUserProfile()` / reinstall-only regeneration.

### 📡 Wire flip to family canon (Phase 3) — **breaking wire change**
- **CHANGED**: batch envelope is now `type: "telemetry_batch"` (was `"batch"`),
  fields ordered `type`/`timestamp`/`batch_size`/`events`.
- **CHANGED**: transport POSTs to `<endpoint>/collector/telemetry` with an
  `X-API-Key` header. `endpoint` is now a **base URL** — new `apiKey:` param on
  `initialize()` supplies the key (omit → header not sent; the Collector 401s).
- **CHANGED**: the wire now carries **only the 12-event / 4-metric canon
  allowlist**. Event renames: `navigation.route_change`→`navigation`,
  `performance.screen_duration` (metric)→`screen.duration` (event),
  `performance.app_startup`→`page_load`, `network.connectivity_change`→
  `network_change`; host `trackEvent(name)`→`custom_event` (name in
  `event.name`); the `user.profile_*` trio folds into one `user.profile.update`.
- **CHANGED**: metric renames `performance.frame_time`→`frame_render_time`,
  `performance.memory_usage`→`memory_usage`, `performance.frame_drop` (event)→
  `long_task` (metric).
- **REMOVED from wire**: `http.error` / `http.slow_request` (fold into
  `http.request`), the 4 internal-noise events (`telemetry.initialized`,
  `*.monitor_initialized`, `performance.system_check`), and the
  `network.quality_score` / `http.response_time` / `performance.startup_time`
  metrics.
- **GUARANTEED**: `location` / `tenant_id` / `geo` are never sent (stripped at
  the context boundary — the Collector injects them). Batches are capped at
  1000 events.
- **CHANGED (crash unification)**: the bare `type:"error"` item is gone — every
  Dart error path (`FlutterError.onError`, `PlatformDispatcher.onError`,
  `runZonedGuarded`, the now-wired isolate error-listener, host `trackError`)
  funnels into one immediate `app.crash` **event** with **unprefixed** keys
  (`message`, `stacktrace`, `exception_type`, `cause="Error"`, `is_fatal=false`)
  and the catching handler in the secondary `crash.source`
  (`flutter_error`/`platform_dispatcher`/`zone`/`isolate`). The client no longer
  derives `crash_hash` / `severity` / `breadcrumbs` — the server computes those.
  Crashes still send immediately and persist+drain on network failure.
- **CHANGED (config)**: `batchSize` / `flushIntervalMs` / `sampleRate` are the
  canon keys; `flushIntervalMs` **defaults to 5000ms** (fixes the latent 5-min
  flush). Old `eventBatchSize` / `batchTimeout` / `maxBatchSize` are deprecated
  (still honored as fallbacks, removed in v3.0.0).

### 🛟 Reliability rail (Phase 3)
- **ADDED**: normal batches now persist on send failure (was crash-only). The
  `OfflineQueue` is one-file-per-batch under
  `<app documents>/edge_telemetry_queue/` — the assembled payload is stored
  verbatim, and draining lists files lexically (== FIFO), POSTs each, and
  deletes on 2xx. No on-device dedup.
- **ADDED**: `RetryTransport` batch backoff `[0, 2s, 8s, 30s]` — a reachable
  failure exhausts the schedule before queueing; an offline result
  (`status == 0`) hands off to the queue immediately.
- **ADDED**: `maxQueueSize` config knob (default 200) — batches drop-oldest
  past the cap; crashes (`crash_` filename prefix) are exempt and never dropped.

### 🎚️ Two-axis sampling (Phase 3)
- **ADDED**: `sampleRate` (config, default 1.0) is now live — rolled **once per
  session** and stored as `session.sampled`. A sampled-out session drops its
  subject-to-sample events coherently (whole session or none). At 1.0 there is
  no roll and `session.sampled` is omitted (wire unchanged).
- **ADDED**: send-priority (immediate vs batched) and sampling (bypass vs
  subject-to-sample) are now orthogonal axes. `app.crash` and the `session.*`
  bookends are immediate+bypass; `user.profile.update` is **batched-but-bypass**
  — an identity mutation always lands even in a sampled-out session.

### 🍞 Breadcrumbs & Flutter diagnostics (Phase 3)
- **CHANGED**: the breadcrumb ring is now **20 entries**, crash-scoped. It is
  attached to every `app.crash` as `crash.breadcrumbs` (JSON-encoded) and never
  appears in the global snapshot. Auto-crumbs now come from navigation, HTTP
  (sanitized **path only** — no query string), and lifecycle transitions;
  `addBreadcrumb(message, {category, level, data})` adds manual ones.
- **ADDED**: `frame_render_time` now carries `build_time_ms` (UI-thread build)
  and `raster_time_ms` (GPU raster) — the UI-vs-GPU jank split.
- **ADDED**: `navigation` and `screen.duration` carry `route.type` and
  `route.has_arguments` (**boolean only** — argument values are never captured).
- **CHANGED**: `page_load` now carries `startup.type` (`cold`/`warm`) and
  `startup.time_to_first_frame_ms`. The latter is **SDK-init-relative** — it
  undercounts everything before `initialize()`, so call it as early as possible
  in `main()`.
- **ADDED**: `app_lifecycle` carries `lifecycle.state` (raw `AppLifecycleState`).
- **ADDED**: every event carries `device.platform_brightness` (`light`/`dark`).
  `device.text_scale_factor` / `device.reduce_motion` are **opt-in** behind the
  new `initialize(captureAccessibilityContext:)` flag (default `false`, pending
  privacy sign-off — they are accessibility-sensitive).

### 📱 Native crash capture — iOS (Phase 4)
- **ADDED**: iOS MetricKit plugin behind the `edge_telemetry/native_crash`
  channel. `MXCrashDiagnostic` → `cause: NativeCrash`, `MXHangDiagnostic` →
  `cause: Hang`, both `is_fatal: true`, `crash.source: metrickit`. Zero
  hand-rolled signal handlers — Apple's supported diagnostic API only.
  Payloads are cached on device and drained on next launch via
  `drainNativeCrashes()`; MetricKit self-dedups and the drain reads-then-clears,
  so an OS crash record is never re-read across launches. Raw call-stack JSON is
  sent for server-side symbolication (no dSYM shipped in the SDK).
- **⚠️ BUILD BREAK**: the package is now an iOS plugin with a **hard iOS 14
  floor** (MetricKit diagnostics require it). Consumers must set
  `platform :ios, '14.0'` (or higher) in their `Podfile`. Android native
  capture ships separately.

### 📱 Native crash capture — Android (Phase 4)
- **ADDED**: Kotlin plugin behind the same `edge_telemetry/native_crash`
  channel. JVM/Kotlin crashes via `Thread.setDefaultUncaughtExceptionHandler`
  on **all** API levels (persist-then-chain, `crash.source: uncaught_handler`);
  native + ANR crashes via `ActivityManager.getHistoricalProcessExitReasons`
  (`ApplicationExitInfo`) on **API 30+** — `REASON_CRASH_NATIVE` →
  `cause: NativeCrash`, `REASON_ANR` → `cause: ANR`, `crash.source:
  app_exit_info`. Zero watchdogs, zero signal handlers. `REASON_CRASH` (JVM)
  from `ApplicationExitInfo` is ignored so JVM crashes aren't double-reported.
- **ADDED**: `sdk.native_capture_tier` on every Android crash payload — `full`
  on API 30+ (JVM + native + ANR), `jvm_only` below (native/ANR is a documented
  gap; the `ApplicationExitInfo` API doesn't exist pre-30). Per-device coverage
  is honest on the dashboard.
- A persisted watermark (last-seen exit timestamp) prevents re-reading OS exit
  records across launches; JVM crash files are read-then-deleted on drain. Raw
  tombstone / ANR traces are sent for server-side symbolication.
- **No minimum-SDK bump** — the existing low floor is preserved
  (`ApplicationExitInfo` is runtime-guarded for API 30+).

### 📱 Native crash convergence (Phase 4)
- **CHANGED**: `drainNativeCrashes()` — pulled once on init — now **routes** each
  native payload into the immediate `app.crash` rail (was contract-only, dropped
  the drain). Native crashes surface as `app.crash` with the OS-supplied `cause`
  (`NativeCrash` / `ANR` / `Hang`), `is_fatal: true`, `crash.source`, and the
  `sdk.native_capture_tier` passthrough carried verbatim — the client synthesizes
  none of it. Identity context is folded in downstream by the Collector; the send
  bypasses the batch (immediate rail).
- **FIXED**: Android `mapExit` signature/call-site mismatch that prevented the
  Kotlin plugin from compiling (`exception_type` now the named `REASON_*` string).
- **Deviation (device-matrix e2e, #29)**: the Dart convergence + routing is
  verified by unit tests (collector → wire, `cause`/`is_fatal`/`sdk.native_capture_tier`
  asserted), but the on-device e2e fatal (iOS MetricKit + Android
  `ApplicationExitInfo` producing `app.crash` on the wire) is **not yet run** —
  no device matrix / CI harness available at this stage. Contingency (spec #15
  Phase 4): if native slips, ship wire-first as v2.0.0 and native as v2.1.0
  (reopens #10). Not triggered — the wiring is in; only device-matrix
  confirmation is outstanding.

### 🧹 Internal
- **REMOVED**: `opentelemetry` dependency, `SpanManager`, `EventTrackerImpl`,
  the `EventTracker` interface, and the `useJsonFormat` dual-backend branches.
- **ADDED**: `NativeCrashChannel` — the pull-only `edge_telemetry/native_crash`
  MethodChannel contract (`drainNativeCrashes()` + documented per-crash payload
  schema) the Phase-4 iOS/Android native plugin builds against. Drained once on
  init and routed to `app.crash` (see Native crash convergence). Internal seam,
  not exported.

## [1.6.0] - 2026-07-10

Backward-compatible cleanup release. Wire format and public API are unchanged
from 1.5.2 — this is a safe drop-in upgrade.

### 🧹 Cleanup & leak fixes
- **FIXED**: `EdgeTelemetry.dispose()` now tears down the event tracker —
  previously the JSON batch timeout `Timer`, the crash-retry `Timer`, and the
  underlying `HttpClient` connection pool were leaked on shutdown.
- **CHANGED**: `EventTracker` interface gained a `dispose()` method
  (internal `lib/src/` type — not part of the public API).
- **REMOVED**: Dead empty file `lib/src/telemetry/edge_telemetry.dart`.
- **REMOVED**: Dead unreachable null-aware fallback on `idleTimeout` in the
  HTTP override.

Wire traffic and dispose-time behaviour are unchanged from 1.5.2 (buffered
events are still dropped on shutdown; flush-on-dispose is deferred to 2.0.0).

## [1.5.2] - 2025-08-29

### 🔧 Critical Error Logging Fix

#### Always-On Error Report Logging
- **FIXED**: Error report logging now always shows, regardless of debug mode setting
- **FIXED**: Enhanced visibility for error telemetry transmission status
- **IMPROVED**: Critical error information is no longer hidden behind debug flags

#### Changes Made
- **JsonEventTracker**: Always logs error report success/failure and offline storage
- **EventTrackerImpl**: Always logs OpenTelemetry error report transmission
- **CrashRetryManager**: Always logs retry attempts and results
- Removed debug mode dependency for error report logging visibility

#### Why This Fix Was Needed
- Error report transmission is critical information developers need to see
- Previous version only showed logging when `debugMode: true` was set
- This caused confusion when error telemetry appeared to not be working
- Error logging should always be visible for debugging and verification

### 🎯 Impact
- **Better Developer Experience**: Immediate visibility when errors are captured and sent
- **Easier Debugging**: No need to enable debug mode to see error telemetry status
- **Production Visibility**: Error transmission status visible in all environments
- **Troubleshooting**: Clear feedback when error reports succeed or fail

## [1.5.1] - 2025-08-29

### 🔍 Enhanced Error Report Logging

#### Console Logging for Error Reports
- **NEW**: Comprehensive console logging when error reports are successfully sent
- **NEW**: Detailed logging for retry attempts with attempt count and metadata
- **NEW**: Mode-specific logging (JSON vs OpenTelemetry) for better debugging
- Enhanced visibility into error report transmission status

#### Logging Features
- **Success Logging**: Shows error message, fingerprint, user ID, session ID, and timestamp
- **Retry Logging**: Displays retry attempt number and detailed context for retried reports
- **Debug Mode Only**: Logging only appears when `debugMode: true` is set
- **Rich Context**: Includes crash fingerprint, user context, and session information

#### Console Output Examples
```
✅ Error report sent successfully
   📊 Error: NetworkException: Connection timeout
   🔍 Fingerprint: Exception_12345_67890
   👤 User: user_1704067200123_abcd1234
   🔄 Session: session_1704067200456_xyz789
   ⏰ Timestamp: 2025-08-29T01:01:52Z

✅ Error report retry successful: crash_1704067200000.json
   📊 Error: NetworkException: Connection timeout
   🔍 Fingerprint: Exception_12345_67890
   🔄 Retry attempt: 2/3
   👤 User: user_1704067200123_abcd1234
   ⏰ Retry timestamp: 2025-08-29T01:01:52Z
```

### 🔧 Technical Implementation
- Enhanced `JsonEventTracker._sendCrashWithRetry()` with detailed success logging
- Enhanced `EventTrackerImpl.trackError()` with OpenTelemetry-specific logging
- Enhanced `CrashRetryManager._retrySingleCrash()` with retry success logging
- All logging respects debug mode settings and provides structured output

### 🎯 Benefits
- **Better Debugging**: Clear visibility when error reports are successfully transmitted
- **Retry Visibility**: Track retry attempts and success rates in console output
- **Development Workflow**: Immediate feedback during development and testing
- **Production Ready**: Debug-only logging ensures no performance impact in production

## [1.5.0] - 2025-08-28

### 🚨 Enhanced Crash Reporting & Context System

#### Crash Fingerprinting
- **NEW**: Automatic crash fingerprinting for grouping similar crashes
- Fingerprint format: `ErrorType_MessageHash_StackFrameHash`
- Enables backend crash grouping and trend analysis
- Included in JSON crash reports

#### Breadcrumb Context System
- **NEW**: Rich crash context via breadcrumb tracking system
- Automatic navigation breadcrumbs for user journey context
- Manual breadcrumb APIs for custom context tracking
- Up to 50 breadcrumbs stored with automatic rotation
- Categories: navigation, user, system, network, ui, custom

#### Offline Crash Storage & Retry
- **NEW**: Offline crash storage when network is unavailable
- Intelligent retry mechanism with exponential backoff (1min → 2min → 4min → 1hr)
- Maximum 3 retry attempts with automatic cleanup
- Stores up to 100 crashes with automatic old crash cleanup
- Network-aware retry scheduling

### 🍞 Breadcrumb Management API
```dart
// Automatic navigation breadcrumbs (zero setup)
Navigator.pushNamed(context, '/checkout'); // Auto-tracked

// Manual breadcrumb tracking
EdgeTelemetry.instance.addUserActionBreadcrumb('button_clicked');
EdgeTelemetry.instance.addSystemBreadcrumb('memory_warning', level: BreadcrumbLevel.warning);
EdgeTelemetry.instance.addNetworkBreadcrumb('connection_lost', level: BreadcrumbLevel.error);
EdgeTelemetry.instance.addUIBreadcrumb('modal_opened');
EdgeTelemetry.instance.addCustomBreadcrumb('Processing payment', data: {'amount': '99.99'});

// Breadcrumb management
List<Breadcrumb> breadcrumbs = EdgeTelemetry.instance.getBreadcrumbs();
EdgeTelemetry.instance.clearBreadcrumbs();
```

### 📊 Enhanced Crash Report Format
```json
{
  "type": "error",
  "fingerprint": "Exception_-1234567890_987654321",
  "breadcrumbs": "[{\"message\":\"Navigated to /checkout\",\"category\":\"navigation\"}]",
  "attributes": {
    "crash.fingerprint": "Exception_-1234567890_987654321",
    "crash.breadcrumb_count": "5",
    "user.id": "user_1704067200123_abcd1234",
    "session.id": "session_1704067200456_xyz789",
    "device.id": "device_1704067200000_a8b9c2d1_android"
  }
}
```

### 🔧 Technical Implementation
- Added `Breadcrumb` model with JSON serialization
- Added `BreadcrumbManager` with automatic rotation and categorization
- Added `CrashStorage` with persistent file-based storage
- Added `CrashRetryManager` with exponential backoff retry logic
- Enhanced `JsonEventTracker` with offline storage and retry integration
- Enhanced `EventTrackerImpl` with breadcrumb support for OpenTelemetry
- Integrated breadcrumb collection in main `EdgeTelemetry` class

### 📦 Dependencies
- Added `path_provider: ^2.1.4` for crash file storage

### 🎯 Benefits
- **Crash Grouping**: Fingerprinting enables backend crash categorization and trend analysis
- **Rich Context**: Breadcrumbs provide detailed user journey context for crash debugging
- **Offline Resilience**: Crashes are never lost due to network issues
- **Smart Retries**: Exponential backoff prevents server overload while ensuring delivery
- **Zero Configuration**: Navigation breadcrumbs work automatically with existing setup
- **Performance Optimized**: Breadcrumb rotation and storage limits prevent memory issues

## [1.4.10] - 2025-08-01

### 🔄 Profile Event System

#### Enhanced User Profile Management
- **NEW**: Dedicated `user.profile_updated` events for backend profile persistence
- **NEW**: Profile versioning system with conflict resolution
- **NEW**: Automatic custom attribute prefixing with `user.` for backend processing
- Profile updates now emit dual events: backend persistence + analytics
- Enhanced debug logging with detailed profile operation visibility

#### Profile Versioning
- **NEW**: Incremental profile version counters prevent update conflicts
- Profile versions persist across app sessions via SharedPreferences
- Each profile update/clear operation increments version number
- Backend can use versions to resolve conflicting profile updates

#### Backend Integration Events
- `user.profile_updated` - Dedicated event for backend profile persistence
- `user.profile_set` - Analytics event (existing, enhanced with versioning)
- `user.profile_cleared` - Analytics event (existing, enhanced with versioning)
- Events include user ID, profile version, and timestamp for proper backend processing

### 📊 Profile Event Format
```json
{
  "type": "event",
  "eventName": "user.profile_updated",
  "attributes": {
    "user.id": "user_1704067200123_abcd1234",
    "user.name": "John Doe",
    "user.email": "john@example.com",
    "user.phone": "+1234567890",
    "user.profile_version": "3",
    "user.profile_updated_at": "2025-08-01T12:00:00Z",
    "user.department": "engineering",
    "user.role": "senior"
  }
}
```

### 🔧 Technical Implementation
- Enhanced `setUserProfile()` method with dual event emission
- Enhanced `clearUserProfile()` method with profile clear events
- Added profile version management with persistent storage
- Custom attributes automatically prefixed with `user.` for backend compatibility
- Comprehensive error handling for profile version storage failures
- Profile version loading integrated into SDK initialization

### 🎯 Benefits
- **Backend Profile Persistence**: Dedicated events enable proper profile storage in databases
- **Conflict Resolution**: Profile versioning prevents race conditions and conflicts
- **Backward Compatibility**: No breaking changes to existing profile API
- **Enhanced Analytics**: Dual events provide both persistence and analytics capabilities
- **Custom Attribute Support**: Automatic prefixing ensures backend compatibility
- **Debug Visibility**: Enhanced logging shows profile operations and event emissions

### 💻 API Usage (No Breaking Changes)
```dart
// Profile updates now emit both backend and analytics events
EdgeTelemetry.instance.setUserProfile(
  name: 'John Doe',
  email: 'john@example.com',
  customAttributes: {
    'department': 'engineering',  // Becomes user.department
    'role': 'senior',            // Becomes user.role
  },
);
// Emits: user.profile_updated (backend) + user.profile_set (analytics)

// Profile clearing also emits backend events
EdgeTelemetry.instance.clearUserProfile();
// Emits: user.profile_updated (backend) + user.profile_cleared (analytics)
```

## [1.3.10] - 2025-01-31

### 🆔 Device Identification System

#### New DeviceIdManager
- **NEW**: Persistent device identification across app sessions
- Device IDs follow format: `device_<timestamp>_<random>_<platform>`
- Example: `device_1704067200000_a8b9c2d1_android`
- Automatically generated on first app install
- Persists across app restarts and sessions
- Platform-aware: android, ios, web, windows, macos, linux, fuchsia

#### Enhanced Device Info Collection
- **NEW**: `device.id` attribute added to all telemetry events and metrics
- Integrated with FlutterDeviceInfoCollector for seamless collection
- Graceful error handling if device ID generation fails
- Format validation ensures data integrity

#### Debug Logging Enhancements
- Device ID now appears in EdgeTelemetry initialization logs
- Format validation logging for troubleshooting
- Enhanced debug output: `🆔 Device ID: device_xxx_xxx_platform`

### 🔧 Technical Implementation
- Added `DeviceIdManager` class with persistent storage via SharedPreferences
- Updated `FlutterDeviceInfoCollector` to include device ID in collection
- Enhanced main `EdgeTelemetry` class with device ID validation and logging
- In-memory caching for performance optimization
- Comprehensive error handling with fallback strategies

### 📊 Device Attributes (Auto-Added to All Events)
```json
{
  "device.id": "device_1704067200000_a8b9c2d1_android",
  "device.model": "Pixel 7",
  "device.manufacturer": "Google",
  "device.platform": "android",
  "app.name": "My App",
  "user.id": "user_1704067200123_abcd1234",
  "session.id": "session_1704067200456_xyz789"
}
```

### 🎯 Benefits
- **Unique Device Tracking**: Persistent device identification across sessions
- **Enhanced Analytics**: Better device-level insights and user journey tracking
- **Data Quality**: Format validation ensures consistent device identification
- **Performance Optimized**: Sub-millisecond response after first generation
- **Privacy Conscious**: Device IDs are app-specific and locally generated

## [1.2.4] - 2024-12-19

### 🔥 Major Changes

#### Auto-Generated User IDs
- **BREAKING**: Removed `setUser()` method - user IDs are now auto-generated
- User IDs are automatically created on first app install and persist across sessions
- New on each app reinstall, same across app sessions
- No developer intervention needed

#### Enhanced Session Tracking
- All telemetry data now includes comprehensive session details
- Session counters track events, metrics, and screen visits in real-time
- First-time user detection and total session counting

### ✨ New Features

#### User Profile Management
- `setUserProfile()` - Set name, email, phone (optional)
- `clearUserProfile()` - Clear profile data (keeps user ID)
- `currentUserId` - Get auto-generated user ID (read-only)
- `currentUserProfile` - Get current profile data (read-only)
- `currentSessionInfo` - Get live session statistics

#### Session Attributes (Auto-Added to All Events)
```json
{
  "session.id": "session_123456789_android",
  "session.start_time": "2024-12-19T15:30:45.123Z",
  "session.duration_ms": "120000",
  "session.event_count": "25",
  "session.metric_count": "12",
  "session.screen_count": "3",
  "session.visited_screens": "home,profile,settings",
  "session.is_first_session": "true",
  "session.total_sessions": "1"
}
```

### 📦 Dependencies
- Added `shared_preferences: ^2.3.3` for persistent storage

### 💻 API Changes

#### Before (v1.1.3)
```dart
// Manual user ID management
EdgeTelemetry.instance.setUser(
  userId: 'user-123',  // Manual
  email: 'user@example.com',
  name: 'John Doe',
);
```

#### After (v1.2.0)
```dart
// Auto user ID + optional profile
await EdgeTelemetry.initialize(/* auto user ID generated */);

EdgeTelemetry.instance.setUserProfile(
  name: 'John Doe',
  email: 'user@example.com',
  phone: '+1234567890',  // NEW
);
```

### 🔧 Internal Changes
- Added `UserIdManager` for persistent user ID generation
- Added `SessionManager` for session lifecycle and statistics
- Enhanced global attributes with automatic session injection
- Navigation tracking now updates session screen counters
- All telemetry events automatically include user ID and session details

### 🎯 Benefits
- **Simplified Setup**: No manual user ID management required
- **Rich Context**: Every event includes complete user and session information
- **Better Analytics**: Track user journeys, session quality, and engagement
- **Privacy Friendly**: User IDs are app-specific and reset on reinstall