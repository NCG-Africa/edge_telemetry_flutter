# Changelog

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