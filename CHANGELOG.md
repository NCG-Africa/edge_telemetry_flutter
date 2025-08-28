# Changelog

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