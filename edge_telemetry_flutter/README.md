# EdgeTelemetry Flutter

🚀 **Truly Automatic** Real User Monitoring (RUM) and telemetry package for Flutter applications. **Zero additional code required** - just initialize and everything is tracked automatically!

## ✨ Features

- 🌐 **Automatic HTTP Request Monitoring** - ALL network calls tracked automatically (URL, method, status, duration)
- 🚨 **Crash & Error Reporting** - Dart errors, native crashes, ANRs and iOS hangs, all as `app.crash`
- 📱 **Automatic Navigation Tracking** - Screen transitions and user journeys with breadcrumb context
- ⚡ **Automatic Performance Monitoring** - Frame drops, memory usage, app startup times
- 🔄 **Automatic Session Management** - User sessions with auto-generated IDs
- 👤 **User Context Management** - Associate telemetry with user profiles
- 🍞 **Crash Context Breadcrumbs** - Rich crash context with automatic navigation breadcrumbs
- 💾 **Offline Queue** - Undeliverable data is persisted to disk and drained on the next successful send
- 🔄 **Retry With Backoff** - Batches retry on `[0, 2s, 8s, 30s]` before they queue
- 📊 **Local Reporting** - Generate comprehensive reports without external dependencies
- 🎯 **Zero Configuration** - Works out of the box with sensible defaults

## 🚀 Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  edge_telemetry_flutter: ^2.0.0
  http: ^1.1.0  # If you're making HTTP requests
```

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
dashboard. No minimum-SDK bump — the existing low floor is preserved.

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

### 🚨 Enhanced Crash & Error Reporting (Zero Setup Required)
```dart
// Any unhandled error anywhere in your app:
throw Exception('Something went wrong');

// Gets automatically tracked with:
// - Full stack trace (grouping hash computed server-side)
// - Rich context via breadcrumbs (navigation, requests, lifecycle)
// - User and session context
// - Device information
// - Sent immediately; persisted to disk if the network is down
```

### 📱 Navigation (One Line Setup)
```dart
Navigator.pushNamed(context, '/profile');  // ✅ Automatically tracked
Navigator.pop(context);                    // ✅ Automatically tracked

// Includes:
// - Screen transitions and timing
// - User journey mapping
// - Session screen counts
```

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
// Every captured failure — Dart error, native crash, ANR, iOS hang — is sent
// immediately as one `app.crash` event, bypassing the batch:
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
    "crash.source": "flutter_error",
    "crash.breadcrumbs": "[{\"message\":\"Navigated to /checkout\",\"category\":\"navigation\"}]"
    // + session, user and device context
  }
}

// Grouping hash and severity are computed server-side — the SDK does not send them.
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