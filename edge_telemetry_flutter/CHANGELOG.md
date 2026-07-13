# Changelog

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