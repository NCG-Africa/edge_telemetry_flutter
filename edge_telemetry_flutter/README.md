# EdgeTelemetry Flutter

🚀 **Truly Automatic** Real User Monitoring (RUM) and telemetry package for Flutter applications. **Zero additional code required** - just initialize and everything is tracked automatically!

## ✨ Features

- 🌐 **Automatic HTTP Request Monitoring** - ALL network calls tracked automatically (URL, method, status, duration)
- 🚨 **Crash & Error Reporting** - Dart errors, native crashes, ANRs and iOS hangs, all as `app.crash`
- 📱 **Automatic Navigation Tracking** - Screen transitions and user journeys with breadcrumb context
- ⚡ **Automatic Performance Monitoring** - Frame drops, memory at the session bookends, app startup times
- 🔄 **Automatic Session Management** - User sessions with auto-generated IDs
- 👤 **User Context Management** - Associate telemetry with user profiles
- 🍞 **Crash Context Breadcrumbs** - Rich crash context with automatic navigation breadcrumbs
- 💾 **Offline Queue** - Undeliverable data is persisted to disk and drained on the next successful send
- 🔄 **Retry With Backoff** - Batches retry on `[0, 2s, 8s, 30s]` before they queue
- 📊 **Local Reporting** - Generate comprehensive reports without external dependencies
- 🎯 **Task Completion** - Declare a multi-screen journey with three calls and
  measure whether users finish it (the one category that needs your code)
- 🎯 **Zero Configuration** - Works out of the box with sensible defaults

## 🚀 Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  edge_telemetry_flutter: ^3.0.0
  http: ^1.2.0  # If you're making HTTP requests
```

### Platform requirements

| | Floor |
|---|---|
| Dart | `>=3.7.0` |
| Flutter | `>=3.29.0` |
| Android `minSdkVersion` | **21** |
| iOS deployment target | **14.0** |

The Dart/Flutter and Android floors **rose in v3.0.0 to match what was already
being enforced** — `device_info_plus` already demanded Dart 3.7 / Flutter 3.29,
and `shared_preferences_android` / `path_provider_android` already declared
`minSdkVersion 21`, so the manifest merger raised every v2 build to 21 while this
package advertised 19. Nothing that built on v2 loses support. The iOS floor is
unchanged.

### iOS requirement (native crash capture)

Native iOS crash/hang capture uses **MetricKit**, which requires a **minimum
deployment target of iOS 14**. Set it in your app's `ios/Podfile`:

```ruby
platform :ios, '14.0'
```

### Android coverage

Android native crash capture is **tiered by OS version**, with no watchdog
threads or hand-rolled signal handlers:

| API level | JVM/Kotlin crashes | Native (NDK) crashes | ANRs | `sdk.native_capture_tier` |
|-----------|:---:|:---:|:---:|:---:|
| **30+**   | ✅ | ✅ | ✅ | `full` |
| **< 30**  | ✅ | ❌ | ❌ | `jvm_only` |

Below API 30, native (NDK) crashes and ANRs are a **documented gap** — the OS
`ApplicationExitInfo` API that surfaces them only exists on API 30+. JVM crashes
are captured on every level via `UncaughtExceptionHandler`. Each captured crash
carries `sdk.native_capture_tier` so per-device coverage is visible on the
dashboard. The API 21 floor is the one an existing dependency already demanded,
not a bump made for crash capture.

## 🧭 Migrating from 2.0.0 to 3.0.0

**The wire changed *and* your code changed** — v2's headline, inverted. No v2
event or metric name was renamed or dropped, so v3 is additive **by name**, and
that is the only sense in which it is additive: additive by *value* and by
*presence* is false seven times (screen dwell stops being its own event, URLs
become paths, memory becomes a different quantity, lifecycle fires twice rather
than six times, iOS `device.name` goes, route names stop being fabricated per
visit, and **crash volume goes from zero to real**).

Eight symbols are hard compile breaks: `enableCrashReporting`,
`enableErrorReporting`, `useJsonFormat`, `batchTimeout`, `maxBatchSize`,
`eventBatchSize`, `withSpan` and `withNetworkSpan`. Plus two platform-floor
corrections, and a dated errata register for telemetry you have **already drawn
conclusions from**.

**Whoever owns your pipeline needs one sentence before ship day:** crashes
accumulated undeliverable since v2.0.0 arrive **in volume, backdated by weeks** —
an entirely historical spike, not a live incident.

👉 **The whole guide is [`MIGRATION.md`](MIGRATION.md).** The full change list is
in [`CHANGELOG.md`](CHANGELOG.md) under `[3.0.0]`.

## 🧭 Migrating from 1.x to 2.0.0

**The wire changed — your code mostly didn't.** Three steps: (1) set the iOS
Podfile floor to `14.0` (MetricKit — the one guaranteed build break), (2) pass
`apiKey:` to `initialize()` and treat `endpoint` as a base URL (`X-API-Key` auth;
posts to `<endpoint>/collector/telemetry`), (3) delete the 4 removed OTel-leak /
long-deprecated symbols if you used them (`startSpan` / `endSpan` /
`activeScreenSpans` / `initialize(runAppCallback:)`). Everything else compiles
unchanged. **The full checklist — removals, deprecated no-ops, and what you
gain — is in [`CHANGELOG.md`](CHANGELOG.md) under `[2.0.0]`.**

## ⚡ Quick Start

### One-Line Setup (Everything Automatic!)

```dart
import 'package:edge_telemetry_flutter/edge_telemetry_flutter.dart';
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🚀 ONE CALL - EVERYTHING IS AUTOMATIC!
  await EdgeTelemetry.initialize(
    endpoint: 'https://your-backend.com', // base URL — SDK posts to /collector/telemetry
    serviceName: 'my-awesome-app',
    apiKey: 'edgekey_xxx_yyy', // sent as X-API-Key (required by the collector)
  );
  
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // 📊 Add this ONE line for automatic navigation tracking
      navigatorObservers: [EdgeTelemetry.instance.navigationObserver],
      home: HomeScreen(),
    );
  }
}
```

> ⏱️ **Call `initialize()` as early as possible in `main()`.** `page_load`'s
> `startup.time_to_first_frame_ms` is measured from SDK init, not process start,
> so anything before this call is not counted.

**That's it! 🎉** Your app now has comprehensive telemetry:
- ✅ All HTTP requests automatically tracked
- ✅ All crashes and errors automatically reported
- ✅ All screen navigation automatically logged
- ✅ Performance metrics automatically collected
- ✅ User sessions automatically managed

## 📊 What Gets Tracked Automatically

### 🌐 HTTP Requests (Zero Setup Required)
```dart
// This request is automatically tracked with full details:
final response = await http.get(Uri.parse('https://api.example.com/users/42'));

// EdgeTelemetry captures:
// - http.url        → 'https://api.example.com/users/{id}'  (path only, id templated)
// - http.method, http.status_code, http.success  (2xx only)
// - http.duration_ms   → before the call, to headers received
// - http.download_ms   → headers received, to the last byte of the body
// - http.connect_ms    → DNS + TCP + TLS, on requests that made a connection
// - http.connection_reused  → measured, not inferred
// - http.response_size + http.response_size_source  (content-length, or decoded bytes)
// - http.seam          → which capture seam saw it
```

The total wall clock is `duration + download`. Time to first byte is
`duration - connect - queue`. Both are derivable, so neither is sent. **A key the seam
could not reach is omitted** — never zeroed, never sentinelled — because a false zero
puts a wrong denominator under somebody's connect-time average.

There is no retry key and there will not be one: at this seam a retry is a new
independent request, indistinguishable from a double-tap or a poll.

**TCP and TLS are never reported separately**, at any tier. Splitting them would mean
handing the platform a socket this SDK upgraded itself, and `dart:io` offers no way to
do that; their sum is `connect - dns` and neither half is guessed. Under an HTTPS proxy
the handshake happens inside the platform's CONNECT tunnel, so TLS is out of reach there
too and `http.connect_ms` measures the proxy connection only.

Enabling HTTP capture installs a connection factory on every `HttpClient`, which is the
only way the connect time and the reuse flag are reachable. The SDK threads your
`SecurityContext`, `badCertificateCallback` and `keyLog` through it by hand, so
**certificate pinning keeps working**, and it chains rather than replaces a
`connectionFactory` you set yourself. Under an HTTPS proxy the TLS handshake happens
inside the platform's CONNECT tunnel, so TLS time is unreachable at any tier.

#### Clients that bypass `HttpOverrides`

`HttpOverrides.global` reaches every `dart:io` socket and nothing else. A client built
on `cupertino_http` (NSURLSession) or `cronet_http` (Cronet) never touches one, so such
an app is not *thinly* covered — it is **totally invisible**, and because the same seam
carries `traceparent`, every one of its requests is also a severed distributed trace.

Hand the client over once, where you build it:

```dart
final client = EdgeTelemetry.instance.captureClient(
  CupertinoClient.defaultSessionConfiguration(),
);
```

**Client in, same type out.** A client that is already captured, a call made before
`initialize()`, and a build with `Capture.http` switched off all hand you back the
client you passed — so wrapping twice is one capture, not two rows.

Handing over a plain `http.Client()` is safe too: that is an `IOClient`, its sockets
already pass the `dart:io` override, and it comes back unwrapped rather than measured
through both seams. No request is ever captured twice.

Rows from this seam carry `http.seam: http_client` and **no** `http.connect_ms`,
`http.dns_ms`, `http.queue_ms` or `http.connection_reused` — the platform client below
the wrapper owns the connection pool, so those are structurally out of reach here.

gRPC, HTTP/2 and Dio's `http2_adapter` stay out of scope: they bypass `package:http`
as well, which is a protocol gap rather than a wrapper gap.

#### `sdk.http_seam_state`

Every item carries which seams are **live** — never how much of your traffic they see,
which the SDK cannot know:

| Value | Meaning |
|---|---|
| `overrides` | The `dart:io` global override is ours. No client wrapped. |
| `wrapper` | The global is **not** ours (you replaced it), but a client was wrapped. |
| `both` | Both seams live. |
| `blind` | Neither. Provable, and the honest answer when the override was replaced and nothing was wrapped. |

It is read fresh on every item rather than fixed at startup — you can replace
`HttpOverrides.global` at any moment and nothing tells the SDK — so one session can
report more than one value.

One case has no client-side signature at all: capture healthy, and every request going
through a bypassing client nobody wrapped. It is deliberately not papered over here —
it is an alert on the backend, on sessions that finalize with
`session.http_request_count == 0` while the seam state says a seam was live.

### 🚨 Enhanced Crash & Error Reporting (Zero Setup Required)
```dart
// Any unhandled error anywhere in your app:
throw Exception('Something went wrong');

// Gets automatically tracked with:
// - Full stack trace (grouping hash computed server-side)
// - An `error.category` taxonomy inferred from the error's exact type
// - Rich context via breadcrumbs (navigation, requests, lifecycle) — a 50-entry
//   ring; a fatal ships all 50, a non-fatal the newest 10
// - User and session context
// - Device information
// - Batched with retries (a fatal crash is sent immediately); persisted to disk
//   if the network is down
```

### 📱 Navigation (One Line Setup)
```dart
Navigator.pushNamed(context, '/profile');  // ✅ Automatically tracked
Navigator.pop(context);                    // ✅ Automatically tracked

// Includes:
// - Screen transitions and timing
// - User journey mapping
// - Session screen counts
// - Dwell time on the screen you just left, on the same `navigation` event
```

Screen names come from `RouteSettings.name`. An unnamed route falls back to its
route **type** (`unnamed_MaterialPageRoute<void>`) — never an identity hash, which
would mint a fresh name on every visit and make every screen-keyed dashboard
carry cardinality equal to your total navigations. Visit identity is `screen.id`.

**Parameterised names are documented, not sanitized.** If you push
`/orders/8412`, that is the screen name you get: the SDK cannot tell a path
segment you meant as a name from one you meant as an id, and guessing would
silently rename your screens. Name such routes yourself
(`RouteSettings(name: '/orders/:id')`) if you want them grouped. The guard if you
don't is the per-session cardinality cap on `screen.name`, `navigation.to` and
`navigation.from` — past 50 distinct values the key becomes
`__over_cardinality__` and `session.cardinality_capped_count` says so.

### ⏱️ Screen Load (Zero Setup Required)

One `screen.load` event per screen entry, at the first terminal it reaches:

| `screen.load.outcome` | Means | Carries `settled_ms`? |
|---|---|---|
| `settled` | First frame reached, nothing this screen requested still in flight, 500 ms of quiet | ✅ |
| `abandoned` | The user navigated away first | ❌ |
| `deadline_exceeded` | Still loading after 10 s | ❌ |
| `backgrounded` | The app was backgrounded first | ❌ |

`screen.load.first_frame_ms` is the first post-frame callback after the route
push — the navigation transition is deliberately excluded, since a transition
duration you chose is not a fact about how slow your screen is. Non-settled
outcomes carry no duration of their own: "how long until the user gave up" does
not belong in the same column as "how long the screen took".

There is **no slow/fast flag on the wire** — banding is a query-time comparison
against your Apdex threshold, so it moves without a client release.

`settled` is **inferred by default**, which is the opposite of the manual-first
norm, on purpose: a manual API is silently missing wherever it isn't called.
`screen.load.source` is on every event (`inferred` or `reported`) so an inferred
number can never be read as a measured one. Override the inference when your last
step is invisible to it — a websocket, a local database, a cache the SDK never
sees:

```dart
// After your content is actually on screen.
EdgeTelemetry.instance.reportScreenSettled();
```

Call it as soon as your content is up. The inference does not wait for you: if
your last step lands more than 500 ms after the quiet window opened, the
`inferred` event has already shipped and the call is a no-op. `settled_ms`
measures to the instant the screen went quiet, **not** to the end of the
window — otherwise every screen would read 500 ms slower than it loaded.

Render-complete and time-to-interactive are **not** collected, and won't be:
Flutter composites one frame from one widget tree (there is no later paint to
name), and a Flutter route's gesture arena is live on frame one (so TTI would be
first frame under a second name).

### 🎞️ Frames (Zero Setup Required)

Frame timings are **aggregated, never streamed**. v2 emitted two items per
frame at 60–120 Hz into a 30-item buffer — roughly 300 items per flush window,
starving every other signal; measuring jank was causing it. v3 emits **at most
two `frame.summary` events per session**, and the per-frame cost is about
eleven scalar operations.

Frames accumulate per **screen segment** — a window closes on a screen change
or after 10 s, whichever comes first, both checked inside the frame callback
(no timer, because a backgrounded Flutter app cannot run one). A window with
no slow frames is discarded. The rest are ranked in a **keep-worst-two
reservoir** on `(frozen frames, slow frames, worst frame)` — absolute counts,
so a five-frame window cannot outrank a six-hundred-frame one — and the two
survivors are sent when the app is backgrounded or the session ends.

| Key | Means |
|---|---|
| `frame.total_frames` | Frames in the window |
| `frame.slow_frames` | Frames over 16 ms |
| `frame.frozen_frames` | Frames over 700 ms (a subset of slow) |
| `frame.slow_frame_rate` | `slow / total` |
| `frame.max_total_duration_ms` | Worst frame, vsync start → raster finish |
| `frame.max_build_duration_ms` | Worst UI-thread build |
| `frame.max_raster_duration_ms` | Worst GPU raster |
| `frame.window_duration_ms` | Wall clock the window spanned |
| `display.refresh_rate` | The panel's actual Hz |
| `screen.name` / `screen.id` | The screen, frozen at window start |

Three things about that table are deliberate and stable:

- **The thresholds are absolute and do not adapt to refresh rate.** The rate is
  recorded, never applied. A per-device budget would make `frame.slow_frames`
  mean something different on every handset and break comparison with the
  sibling SDKs and with platform vitals.
- **Total frame duration is the framework's own span** (vsync start → raster
  finish). v2 added the build and raster durations, which run on two
  *pipelined* threads, so it over-reported drops.
- **The event carries no trace or action id at all.** A ten-second window spans
  several user actions; attributing it to one of them would be false precision.
  A window is not an action.

The timestamp is backdated to the window start, and the screen keys are frozen
there too, so a window held in the reservoir is never attributed to whatever
screen you happened to be on when it shipped.

**`frame.total_frames` is not a fleet denominator.** Only windows containing
jank are eligible, and at the default tier only the two worst of those survive:
the two rows are exemplars — *"the worst two screen segments in this session"* —
not a sample. Use `screen.load` / `navigation` counts for coverage. Turn on
`Capture.screenWindowedFrames` (diagnostic) to get **every** qualifying window
as it closes; it *replaces* the reservoir rather than adding to it, so nothing
is ever counted twice.

`Capture.longTask` (diagnostic) adds one `long_task` metric per **frozen** frame
— redefined from v2's every-dropped-frame, where a single two-second stall
exhausted the whole session's allowance in one go. It is independent of
`Capture.frames`: turn frames off and long tasks on and you get the frozen-frame
metric with no windowing behind it.

Backgrounding flushes the reservoir but does not empty it. A survivor already
sent stays as a ranking incumbent, so a session you background and return to
neither re-sends the same window nor starts ranking from scratch — a later
window costs an item only by being genuinely worse.

### 👆 User Actions (Zero Setup Required)
```dart
ElevatedButton(
  onPressed: () {
    // Optional: name the action the user just performed. It names the tap
    // EdgeTelemetry already captured — it does not emit an event of its own.
    EdgeTelemetry.instance.trackAction('transfer');
    _submit();
  },
  child: const Text('Send'),
)

// Every completed tap, long-press and swipe is captured from a global pointer
// route — no widget changes — and each one opens the action every request,
// crash and frame that follows is attributed to. Captured:
// - ui.type (tap / long_press / swipe) and ui.direction on a swipe
// - ui.screen, and ui.target + ui.name_source when trackAction named it
// - session.action_count on the session summary
//
// A scroll coming to a stop is not an action and mints nothing. Swipe events
// are diagnostic-tier (off by default); the action itself is still recorded.
// Call trackAction synchronously from the handler — after an `await` it still
// names the action but misses that one event. It takes no attributes map (use
// trackEvent), and an action has no duration and no outcome to close.
```

### 🎯 Task Completion (Three Calls — the one category you have to opt into)

Screen load tells you whether a screen worked. A task tells you whether the
**journey** worked — an onboarding, a transfer — and nothing can infer that for
you, because only you know where your journey begins and ends.

```dart
EdgeTelemetry.instance.startTask('transfer');     // screen 1 of 4
// …amount, recipient, OTP, receipt…
EdgeTelemetry.instance.completeTask('transfer');  // or failTask('transfer')
```

String-keyed and with no handle to thread: a transfer spans four routes, so a
handle object would have to travel through your state container or your route
arguments — friction on the one feature whose only weakness is adoption. The
calls are fire-and-forget: a name that was never started, or was already closed,
does nothing. There is nothing to leak and nothing to dispose.

**The start costs no wire item.** One `task.complete` event is emitted at the
terminal:

| Attribute | Value |
|---|---|
| `task.name` | the string you passed |
| `task.outcome` | `completed` / `failed` / `abandoned` |
| `span.duration_ms` | time on task — the same span duration key HTTP uses |
| `task.abandon_source` | `session_end` or `launch_recovery`, abandoned only |

A second `startTask` under the same name supersedes the first. Keep task names a
small fixed set — build one from an order id and it is sentinelled past 50
distinct values in a session, the same guard `screen.name` gets. Trace context is
frozen at the **start**, so the terminal is attributed to the action that began
the journey rather than to whatever tap happens to be open minutes later — and a
task mints no root of its own, so requests inside it keep exactly one parent.

**Abandonment fires on session finalize only.** Navigating away is not
abandonment — the four-route transfer above navigates four times. Backgrounding
is not abandonment either: reading the OTP is step 2 of the happy path, and
treating it as a failure would report the commonest mobile-banking flow as
broken. There is no task timeout of its own; the 30-minute session idle window is
the cap.

A task still open when the process dies is reported on the next launch with
`task.abandon_source: launch_recovery`, carrying the trace ids frozen in the
process that died and a duration measured to the session's **last activity** —
not to the wall clock, so a phone left in a pocket for two hours does not report
a two-hour task. That value also says what the SDK cannot: native crashes are
drained *after* the recovery finalize, so a crash and an OS kill are
indistinguishable at that instant. Join them on `session.id` in your backend
rather than assuming.

There is **no Apdex band on the wire** — zero events, zero attributes, zero
bytes. The threshold belongs per target and moves without a client release, so
banding is a query-time comparison against `span.duration_ms`.

Coverage for this category is **conditional**, in those words: the signal exists
only where you make the calls. The usual objection to a manual API does not apply
here — the manual helper that got no adoption duplicated a signal already
captured automatically, so its failure mode was double-counting. This one has no
automatic source at all.

## 🎛️ Configuration Options

Collection is **two fields**: a `tier` dial and a `captureOverrides` map that works in
both directions. There is no enable/disable pair to keep consistent.

```dart
await EdgeTelemetry.initialize(
  endpoint: 'https://your-backend.com',  // base URL — SDK posts to /collector/telemetry
  serviceName: 'my-app',
  apiKey: 'edgekey_xxx_yyy',             // sent as X-API-Key

  // 🎯 The dial — how much to collect
  tier: CollectionTier.standard,     // essential | standard (default) | diagnostic

  // 🔪 The scalpel — one specific thing, either direction
  captureOverrides: {
    Capture.http: false,             // turn a standard capture off
    Capture.httpQueryString: true,   // turn a diagnostic capture on
  },

  // 🔧 Advanced Options
  debugMode: true,                   // Enable console logging
  batchSize: 30,                     // Events per batch
  flushIntervalMs: 5000,             // Send a partial batch after this long
  maxQueueSize: 200,                 // Offline batch files kept before drop-oldest
  sampleRate: 1.0,                   // Fraction of sessions kept (0.0–1.0). Rolled
                                     // once/session: a sampled-out session drops its
                                     // events, but crashes, session bookends, and
                                     // user.profile.update always land. 1.0 = keep all.
  enableLocalReporting: true,        // Store data locally for reports (a sink, not a
                                     // capture — it never touches the wire)

  // 🙈 One redaction hook, over each item's own attributes. Return the value to
  //    send, or null to drop the key. It never sees the ~30-key context snapshot.
  redactAttribute: (key, value) => key == 'checkout.email' ? null : value,

  // 🔗 Hosts a W3C `traceparent` may be injected into. EMPTY = DARK: no header
  //    is sent anywhere until you list a host.
  traceHostAllowlist: ['api.myapp.com', '.internal.myapp.com'],

  // 🏷️ Global attributes added to all telemetry
  globalAttributes: {
    'app.environment': 'production',
    'app.version': '1.2.3',
    'user.tier': 'premium',
  },
);

runApp(MyApp());
```

### Tiers

| Tier | Meaning |
|---|---|
| `essential` | Never shed, never sampled, no off-switch: crashes, session bookends, profile updates. Sheds everything else — the real answer to "send me almost nothing". |
| `standard` | **Default.** Everything above plus HTTP, navigation, screen load, actions, frames, health, connectivity, lifecycle. Subject to the one per-session sampling roll. |
| `diagnostic` | Everything above plus the high-volume / privacy-sensitive variants: swipes, tap coordinates, full HTTP URLs (query included), device fingerprint, accessibility context, extra lifecycle states, long tasks, per-screen frame summaries. |

The `Capture` member set is fixed here so no later release moves it, but a member only
does something once its emitter ships. Live today: `http`, `httpQueryString`,
`httpRequestPhases`, `navigation`, `connectivity`, `frames`, `health`, `lifecycle`,
`lifecycleTransitions`, `accessibilityContext`. The rest are declared and inert until
their own release.

A tier is an **on/off plus a shed rank**, never a sampling axis — `sampleRate` stays the
one roll over the whole session. If a session blows through its item budget the SDK
sheds a *whole tier* (`diagnostic`, then `standard`, never `essential`) and reports
every shed on `session.dropped_item_count` / `session.dropped_reasons`.

### Distributed tracing

Requests to a host you list carry a W3C `traceparent`, so a mobile tap and the backend
span it caused sit in one trace. It is `traceparent` only — no `tracestate`, no B3 — and
spans are attributes on the events you already get, never a separate span object or
event type.

```dart
traceHostAllowlist: ['api.myapp.com', '.internal.myapp.com'],
```

Matching is **exact host, or a dot-anchored suffix of at least two labels**:
`.myapp.com` matches `api.myapp.com` and never `api.myapp.com.evil.com`. **An empty
allowlist — the default — means no header is injected anywhere.** The header carries
your internal trace topology, so listing a host is a decision to disclose it to that
host; a request to an unlisted host is still captured and still carries local trace ids,
only the header is withheld.

Every `http.request` says what happened in `traceparent.outcome`:

| Value | Meaning |
|---|---|
| *(absent)* | Not traced — the SDK's own upload, or a request that never reached a socket. |
| `skipped_off_allowlist` | Host not listed. Ids stamped locally, **no header sent**. |
| `adopted` | You had already set your own `traceparent`. It is left untouched and its ids are mirrored; the request stays joined to your tap through `rum.action.id`. |
| `injected_attributed` | Injected under the user action that made the call. |
| `injected_expired` | That action had aged out, or the session rotated while the request was in flight. Re-rooted as a parentless request. |
| `injected_unattributed` | Nothing was in progress when the call was made. Re-rooted as a parentless request. |

The context is frozen at the **synchronous call instant**, before the connection is even
attempted — a cold connect measured 509 ms, and reading it back at send time would
silently reparent requests onto whatever the user tapped meanwhile. The header and the
event describing that request are built from the same frozen copy, so they can never
disagree.

There is no separate trace sampling rate: `sampleRate`'s one per-session roll governs,
and the sampled flag on the header is literally set.

**Known limitation — redirects.** `dart:io` copies request headers onto a redirect
target inside `close()`, below this SDK's wrapper, so a 302 from a listed host to an
unlisted one carries the `traceparent` with it. Closing that would mean the SDK taking
over redirect handling — changing your app's HTTP behaviour to serve a telemetry
concern — so it is declined and documented rather than silently fixed.

### Device health

**Health is not a time series.** v2 sampled memory every 10 seconds and ran a
30-second system check — roughly 58 items a session into a stream with no named
consumer. v3 ships two signals instead, and neither of them polls:

- **Memory at the two session bookends** (`memory_usage`, `Capture.health`): one
  reading when the session opens, one when the app is backgrounded. The quantity
  is read **natively** — `phys_footprint` on iOS, total PSS on Android — because
  Dart's `ProcessInfo.currentRss` is the wrong number on both platforms and the
  two are not comparable: it under-reports against the footprint iOS jetsams on,
  and over-reports on Android, where the shared Flutter engine library counts
  against your process. `memory.source` (`footprint` / `pss`) says which
  quantity a row carries, so the v2→v3 step change in your charts is legible
  rather than mysterious.
- **A five-key fault bundle on fatal crashes only** — battery level, charging,
  power-save mode, thermal state, orientation. They are read off the dying
  thread, where four binder calls are free; doing them continuously would cost a
  chatty app frames. Android reads them in its uncaught-exception handler; on
  iOS the keys are **absent**, because MetricKit hands a crash over on the next
  launch, in a different process, and this launch's battery level is not that
  crash's battery level.

On iOS the first health read switches on `UIDevice.isBatteryMonitoringEnabled`
— the only way to read a battery level there. It happens on first read rather
than at plugin registration, so turning `Capture.health` off means the SDK never
touches that host-app singleton at all; it is never switched back off, because
your app may have wanted it on.

`device.thermal_state` is a **normalised string** — `nominal`, `fair`, `serious`,
`critical` — never the platform ordinal. Android has seven thermal statuses and
iOS four, and they disagree on what the same integer means (Android's `2` is
MODERATE, iOS's is serious).

**A key the platform cannot answer is omitted, never sentinelled.** No `-1`
battery level, no `"unknown"` thermal state: absent beats a number a dashboard
will happily average.

**Removed from device context in v3:** `device.name` (the only key that could
carry a human's name — iOS defaults to "Marvin's iPhone") and
`device.identifier_for_vendor` (**redundant, not a privacy concession**:
`device.id` sits beside it, is minted by this SDK and survives a reinstall,
where the vendor id does not). Carrier was never built — no consumer, and on iOS
permanently unreachable. `device.fingerprint` **stays**: despite the name it is
Android OS build metadata, identical across every device on that build.

**Added:** `sdk.version`, so a backend can tell a fixed defect from a live one.

### iOS privacy manifest

The package ships its own `PrivacyInfo.xcprivacy`:

- **`NSPrivacyAccessedAPITypes` is empty.** No required-reason API is used. The
  one signal that would justify a declaration — a true process-start cold start
  — is something Dart structurally cannot see, so the launch mark this SDK
  reports is **SDK-init to first frame**, not process-start to first frame.
  Storage headroom was dropped for the same reason.
- **`NSPrivacyTracking` is false** and the tracking-domain list is empty.
- **Nine collected data types, all declared linked to identity.** `device.id`
  rides every item and `setUserProfile()` exists, so "unlinked" would be a lie —
  one that two widely-used peers tell.

**Standing rule for this package:** an iOS required-reason API is adopted only if
an approved reason **both** fits our use **and** permits off-device
transmission, and the declaration is made in *this* package's manifest — never
inherited from a dependency's. (One existing dependency triggers an undeclared
disk-space access on every consumer app today; it is filed upstream. The call is
in their binary, so nothing in our manifest discharges it.)

### Privacy

PII partitions by **who chose the value**.

- **The SDK redacts what it collected.** `http.url` defaults to scheme, host and path
  — no query string, no fragment, no userinfo — and every request says so in
  `http.url_redacted`. Path segments that are all digits, a UUID, or 20+ hex characters
  become `{id}`. Turn `Capture.httpQueryString` on to get the full URL back at the
  `diagnostic` tier.
- **The SDK caps what the developer named.** Any one attribute key may carry 50 distinct
  values per session; the 51st and everything after it becomes `__over_cardinality__`,
  counted on `session.cardinality_capped_count`. URL templating exists mostly to keep a
  REST app under this cap — untemplated, a typical session breaches 50 distinct URLs and
  the key degrades to a sentinel *after* the real ids have already shipped.
- **The developer decides about what they supplied.** `redactAttribute` runs once per
  item, over the attributes the *consumer* passed to `trackEvent`, `trackMetric` or a
  profile update. It never sees the context snapshot (that would be ~30 callbacks per
  item on the UI isolate for values the SDK chose itself) and never the SDK's own item
  keys, so a hook returning null for a key it does not recognise cannot drop a span id
  or a stack trace.

The cap follows the same split: consumer-named keys, plus `http.url`, which is the one
SDK key that is a label rather than a measurement. The SDK's ids, timestamps and
durations are unique per item by design and are never capped.

### Delivery

Every POST is gzipped. If the collector rejects a compressed body with a 400, the SDK
re-POSTs it once uncompressed and — only if that succeeds — stays uncompressed for the
rest of the launch. There is no flag to set and no version to negotiate; the cost of a
collector that cannot decompress is one wasted POST per launch.

A 4xx is dropped, never retried and never queued: a payload the collector refuses will
be refused every time. Anything else is retried on the `[0, 2s, 8s, 30s]` backoff and
then stored on disk, FIFO, drained five files at a time after each successful send.
Crashes drain first and have their own 50-file cap; a file that has failed five
delivery attempts is dropped. Every drop is counted on
`session.dropped_item_count` / `session.dropped_reasons` (`http_400`,
`queue_overflow`, `queue_attempts_exhausted`, `queue_corrupt`) — the SDK never
discards silently. A drain cycle that finds the device offline is abandoned
untouched, so no stored payload spends an attempt on the weather.

### There is no crash off-switch

`Capture` has no `crash`, `session`, `errors` or `profile` member, and that gap is
deliberate: an SDK reporting no crashes must never be indistinguishable from one
configured not to. If the concern is privacy, note that `app.crash` accepts **no
arbitrary consumer attributes** — the only consumer data that can reach it is an
exception's own text. If it is volume, crash is ≤1% of a session's items;
`tier: CollectionTier.essential` is the knob you want.

## 👤 User Management

### 🔄 Profile Events

Setting or clearing a profile emits one `user.profile.update` event. It is batched like
everything else, but exempt from sampling — identity changes always reach the backend.

```dart
// Set user profile information (optional)
EdgeTelemetry.instance.setUserProfile(
  name: 'John Doe',
  email: 'john@example.com',
  phone: '+1234567890',
  customAttributes: {
    'department': 'engineering',  // Automatically becomes user.department
    'role': 'senior',            // Automatically becomes user.role
    'subscription': 'premium',   // Automatically becomes user.subscription
  },
);
// ✅ Emits: user.profile.update

// Clear user profile
EdgeTelemetry.instance.clearUserProfile();
// ✅ Emits: user.profile.update

// Get current user info
String? userId = EdgeTelemetry.instance.currentUserId;
Map<String, String> profile = EdgeTelemetry.instance.currentUserProfile;
Map<String, dynamic> session = EdgeTelemetry.instance.currentSessionInfo;
```

### 📊 Profile Event Format

Backend profile events include versioning and structured data:

```json
{
  "type": "event",
  "eventName": "user.profile.update",
  "attributes": {
    "user.id": "user_1704067200123_a8b9c2d1e0f34567",
    "user.name": "John Doe",
    "user.email": "john@example.com",
    "user.phone": "+1234567890",
    "user.profile_version": "3",
    "user.profile_updated_at": "2025-08-01T12:00:00Z",
    "user.department": "engineering",
    "user.role": "senior",
    "user.subscription": "premium"
  }
}
```

### 🎯 Key Features

- **Stable User ID**: `identify`ing a user never changes `user.id`, so anonymous and identified activity stay on one timeline
- **Profile Versioning**: Automatic conflict resolution with incremental version numbers
- **Custom Attribute Prefixing**: All custom attributes automatically prefixed with `user.`
- **Never Sampled Out**: Profile updates bypass the session sampling roll

## 📊 Manual Event Tracking (Optional)

While most telemetry is automatic, you can add custom business events:

### String Attributes (Traditional)
```dart
EdgeTelemetry.instance.trackEvent('user.signup_completed', attributes: {
  'signup.method': 'email',
  'signup.source': 'homepage_cta',
});

EdgeTelemetry.instance.trackMetric('checkout.cart_value', 99.99, attributes: {
  'currency': 'USD',
  'items_count': '3',
});
```

### Object Attributes (Recommended)
```dart
// Custom objects with toJson()
class PurchaseEvent {
  final double amount;
  final String currency;
  final List<String> items;
  
  PurchaseEvent({required this.amount, required this.currency, required this.items});
  
  Map<String, dynamic> toJson() => {
    'amount': amount,
    'currency': currency,
    'items_count': items.length,
    'categories': items.join(','),
  };
}

final purchase = PurchaseEvent(
  amount: 149.99,
  currency: 'USD', 
  items: ['laptop', 'mouse'],
);

EdgeTelemetry.instance.trackEvent('purchase.completed', attributes: purchase);
```

### Mixed Types (Auto-Converted)
```dart
EdgeTelemetry.instance.trackEvent('profile_form_submitted', attributes: {
  'age': 25,                    // int -> "25"
  'is_premium': true,           // bool -> "true"
  'interests': ['tech', 'music'], // List -> "tech,music"
  'updated_at': DateTime.now(), // DateTime -> ISO string
});
```

### Enhanced Error Tracking
```dart
// Manual error tracking with breadcrumb context
try {
  await riskyOperation();
} catch (error, stackTrace) {
  EdgeTelemetry.instance.trackError(error, 
    stackTrace: stackTrace,
    attributes: {'context': 'payment_processing'});
}

// `error.category` is inferred from the error's exact type — a SocketException is
// `network`, a TimeoutException `timeout`, a FormatException `parse`, a
// FileSystemException `storage`. Two categories have no platform type that means
// them, so declare those:
try {
  await transfer();
} on UnauthorizedException catch (error, stackTrace) {
  EdgeTelemetry.instance.trackError(error,
    stackTrace: stackTrace,
    category: ErrorCategory.auth);      // or ErrorCategory.business
}
// The wire records which it was: `error.category_source` is `inferred` or
// `declared`, never silently one dressed as the other.

// Add custom breadcrumbs for crash context
EdgeTelemetry.instance.addUserActionBreadcrumb('payment_initiated');
EdgeTelemetry.instance.addCustomBreadcrumb('Processing payment', 
  level: BreadcrumbLevel.info,
  data: {'amount': '99.99', 'currency': 'USD'});
```

## 📋 Local Reporting

Generate comprehensive reports from collected data:

```dart
// Enable local reporting
await EdgeTelemetry.initialize(
  endpoint: 'https://your-backend.com',
  serviceName: 'my-app',
  enableLocalReporting: true,
);

runApp(MyApp());

// Generate reports
final summaryReport = await EdgeTelemetry.instance.generateSummaryReport(
  startTime: DateTime.now().subtract(Duration(days: 7)),
  endTime: DateTime.now(),
);

final performanceReport = await EdgeTelemetry.instance.generatePerformanceReport();
final behaviorReport = await EdgeTelemetry.instance.generateUserBehaviorReport();

// Export to file
await EdgeTelemetry.instance.exportReportToFile(
  summaryReport,
  '/path/to/report.json'
);
```

## 🚀 Advanced Features

### 🍞 Breadcrumb Management
```dart
// Add breadcrumbs for crash context (automatic navigation breadcrumbs included)
EdgeTelemetry.instance.addNavigationBreadcrumb('/checkout');
EdgeTelemetry.instance.addUserActionBreadcrumb('button_clicked', 
  data: {'button_id': 'purchase_now'});
EdgeTelemetry.instance.addSystemBreadcrumb('memory_warning', 
  level: BreadcrumbLevel.warning);
EdgeTelemetry.instance.addNetworkBreadcrumb('connection_lost', 
  level: BreadcrumbLevel.error);
EdgeTelemetry.instance.addUIBreadcrumb('modal_opened', 
  data: {'modal_type': 'payment'});

// Get current breadcrumbs
List<Breadcrumb> breadcrumbs = EdgeTelemetry.instance.getBreadcrumbs();

// Clear breadcrumbs
EdgeTelemetry.instance.clearBreadcrumbs();
```

### 🚨 Crash Reports
```dart
// Every captured failure — Dart error, native crash, ANR, iOS hang — is one
// `app.crash` event. A **fatal** (native crash, ANR, hang) is POSTed immediately,
// because its process is dying. A **non-fatal** Dart error batches, so it earns
// the pipeline's retries and the offline queue instead of one attempt — and one
// error thrown from a `build()` method becomes items in a batch rather than a
// POST per throw. Neither is ever sampled away.
{
  "type": "event",
  "eventName": "app.crash",
  "timestamp": "2026-07-13T12:00:00.000Z",
  "attributes": {
    "message": "Exception: payment failed",
    "stacktrace": "#0  ...",
    "exception_type": "_Exception",
    "cause": "Error",              // Error | NativeCrash | ANR | Hang
    "is_fatal": "false",           // Dart errors are non-fatal — the app survived
    "handled": "true",             // a live catch, not an uncaught handler
    "error.category": "network",   // network|timeout|auth|parse|storage|business|unknown
    "error.category_source": "inferred",   // inferred | declared
    "crash.source": "flutter_error",
    "crash.breadcrumbs": "[{\"message\":\"Navigated to /checkout\",\"category\":\"navigation\"}]"
    // + session, user and device context
  }
}

// Grouping hash and severity are computed server-side — the SDK sends no error id
// and no client-side fingerprint.
//
// Per session a non-fatal is capped at 5 per exception-type-and-top-frame and 50
// overall; the overflow is counted on `session.finalized` rather than dropped
// silently. An HTTP failure emits no crash event at all — the status code and
// `http.error` already ride `http.request`, so 4xx-vs-5xx is a query, not a
// second item. The SDK's own internal failures are tagged `crash.source: "sdk"`
// and stay off your session error and crash counts.
```

### 💾 Offline Queue
```dart
// Nothing is dropped on a bad network. A batch retries on [0, 2s, 8s, 30s]; if it
// still fails it is written to disk and drained FIFO on the next successful send or
// on the next app launch. Crashes are written immediately on failure and are never
// evicted — the 200-file cap (maxQueueSize) drops the oldest ordinary batches only.
// No manual control needed.
```

### Network-Aware Operations
```dart
// Get current network status
String networkType = EdgeTelemetry.instance.currentNetworkType;
Map<String, String> connectivity = EdgeTelemetry.instance.getConnectivityInfo();
```

## 🔒 Privacy & Security

- **No PII by default**: URLs ship path-only with ids templated, and only technical
  telemetry plus user-provided profile data leaves the device. See
  [Privacy](#privacy) for the three-way split and `redactAttribute`.
- **Local-first option**: Store data locally instead of sending to backend
- **Configurable**: Disable any monitoring component you don't need
- **Transparent**: Full control over what data is collected and sent

## 🐛 Troubleshooting

### Debug Information
```dart
// Enable detailed logging
await EdgeTelemetry.initialize(
  endpoint: 'https://your-backend.com',
  serviceName: 'my-app',
  debugMode: true,  // Shows all telemetry in console
);

runApp(MyApp());

// Check current status
print('Initialized: ${EdgeTelemetry.instance.isInitialized}');
print('Session: ${EdgeTelemetry.instance.currentSessionInfo}');
```

### Common Issues

**HTTP requests not being tracked:**
- Ensure EdgeTelemetry is initialized before any HTTP calls
- Don't set custom `HttpOverrides.global` after initialization
- Using `cupertino_http` / `cronet_http`? They bypass `HttpOverrides` entirely — pass
  the client through `EdgeTelemetry.instance.captureClient(...)`. Check
  `sdk.http_seam_state` on any item to see which seams are live
- A response whose body is never read is never reported — `dart:io` requires the body
  be drained or the connection stalls, so drain it (`package:http` and Dio already do)

**Navigation not tracked:**
- Add `EdgeTelemetry.instance.navigationObserver` to `MaterialApp.navigatorObservers`

**Events not appearing in backend:**
- Check `debugMode: true` for console logs
- Verify endpoint URL and network connectivity
- **Custom metric names are dropped.** `trackMetric()` takes any name, but only
  the four canon metric names reach the wire (`frame_render_time`,
  `memory_usage`, `long_task`, `resource_timing`). `trackEvent()` is safe — it
  always ships as `custom_event` with your name as an attribute. Every drop
  prints under `debugMode: true` and is counted on the session's closing event
  as `session.dropped_item_count` / `session.dropped_reasons`, so you can see
  the loss on your dashboard without attaching a debugger.

## 🎯 Why EdgeTelemetry?

**Before EdgeTelemetry:**
```dart
// Manual HTTP tracking 😫
final stopwatch = Stopwatch()..start();
try {
final response = await http.get(url);
stopwatch.stop();
analytics.track('http_request', {
'url': url.toString(),
'status': response.statusCode,
'duration': stopwatch.elapsedMilliseconds,
});
} catch (error) {
crashlytics.recordError(error, stackTrace);
}
```

**With EdgeTelemetry:**
```dart
// Automatic tracking 🎉
final response = await http.get(url);
// That's it! Everything is tracked automatically
```

## 📄 License

MIT License

---

**EdgeTelemetry: Because telemetry should be invisible to developers and comprehensive for analytics.** 🚀