# EdgeTelemetry Flutter

🚀 **Truly Automatic** Real User Monitoring (RUM) and telemetry package for Flutter applications. **Zero additional code required** - just initialize and everything is tracked automatically!

## ✨ Features

- 🌐 **Automatic HTTP Request Monitoring** - ALL network calls tracked automatically (URL, method, status, duration)
- 🚨 **Automatic Crash & Error Reporting** - Global error handling with full stack traces
- 📱 **Automatic Navigation Tracking** - Screen transitions and user journeys
- ⚡ **Automatic Performance Monitoring** - Frame drops, memory usage, app startup times
- 🔄 **Automatic Session Management** - User sessions with auto-generated IDs
- 👤 **User Context Management** - Associate telemetry with user profiles
- 📊 **Local Reporting** - Generate comprehensive reports without external dependencies
- 🔧 **JSON & OpenTelemetry Support** - Industry-standard telemetry formats
- 🎯 **Zero Configuration** - Works out of the box with sensible defaults

## 🚀 Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  edge_telemetry_flutter: ^1.4.10
  http: ^1.1.0  # If you're making HTTP requests
```

## ⚡ Quick Start

### One-Line Setup (Everything Automatic!)

```dart
import 'package:edge_telemetry_flutter/edge_telemetry_flutter.dart';
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🚀 ONE CALL - EVERYTHING IS AUTOMATIC!
  await EdgeTelemetry.initialize(
    endpoint: 'https://your-backend.com/api/telemetry',
    serviceName: 'my-awesome-app',
    runAppCallback: () => runApp(MyApp()),
  );
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
final response = await http.get(Uri.parse('https://api.example.com/users'));

// EdgeTelemetry captures:
// - URL, Method, Status Code
// - Response time, Size
// - Success/Error status
// - Performance category
```

### 🚨 Crashes & Errors (Zero Setup Required)
```dart
// Any unhandled error anywhere in your app:
throw Exception('Something went wrong');

// Gets automatically tracked with:
// - Full stack trace
// - User and session context
// - Device information
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

## 🎛️ Configuration Options

```dart
await EdgeTelemetry.initialize(
endpoint: 'https://your-backend.com/api/telemetry',
serviceName: 'my-app',
runAppCallback: () => runApp(MyApp()),

// 🎯 Monitoring Controls (all default to true)
enableHttpMonitoring: true,        // Automatic HTTP request tracking
enableNetworkMonitoring: true,     // Network connectivity changes
enablePerformanceMonitoring: true, // Frame drops, memory usage
enableNavigationTracking: true,    // Screen transitions

// 🔧 Advanced Options
debugMode: true,                   // Enable console logging
useJsonFormat: true,              // Send JSON (recommended)
eventBatchSize: 30,               // Events per batch
enableLocalReporting: true,       // Store data locally for reports

// 🏷️ Global attributes added to all telemetry
globalAttributes: {
'app.environment': 'production',
'app.version': '1.2.3',
'user.tier': 'premium',
},
);
```

## 👤 User Management

### 🔄 Profile Events (v1.4.10+)

Profile updates now emit **dual events** for enhanced backend integration:
- `user.profile_updated` - Dedicated event for backend profile persistence
- `user.profile_set` - Analytics event for tracking profile changes

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
// ✅ Emits: user.profile_updated (backend) + user.profile_set (analytics)

// Clear user profile
EdgeTelemetry.instance.clearUserProfile();
// ✅ Emits: user.profile_updated (backend) + user.profile_cleared (analytics)

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
  "eventName": "user.profile_updated",
  "attributes": {
    "user.id": "user_1704067200123_abcd1234",
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

- **Profile Versioning**: Automatic conflict resolution with incremental version numbers
- **Custom Attribute Prefixing**: All custom attributes automatically prefixed with `user.`
- **Backend Integration**: Dedicated events enable proper profile persistence in databases
- **Backward Compatibility**: No breaking changes to existing profile API
- **Debug Visibility**: Enhanced logging shows profile operations and event emissions

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
EdgeTelemetry.instance.trackEvent('user.profile_updated', attributes: {
  'age': 25,                    // int -> "25"
  'is_premium': true,           // bool -> "true"
  'interests': ['tech', 'music'], // List -> "tech,music"
  'updated_at': DateTime.now(), // DateTime -> ISO string
});
```

### Error Tracking
```dart
// Manual error tracking (usually not needed due to automatic crash reporting)
try {
  await riskyOperation();
} catch (error, stackTrace) {
  EdgeTelemetry.instance.trackError(error, 
    stackTrace: stackTrace,
    attributes: {'context': 'payment_processing'});
}
```

## 📋 Local Reporting

Generate comprehensive reports from collected data:

```dart
// Enable local reporting
await EdgeTelemetry.initialize(
  // ... other config
  enableLocalReporting: true,
);

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

### Network-Aware Operations
```dart
// Get current network status
String networkType = EdgeTelemetry.instance.currentNetworkType;
Map<String, String> connectivity = EdgeTelemetry.instance.getConnectivityInfo();
```

### Custom Span Management (OpenTelemetry mode)
```dart
// Automatic span management for complex operations
await EdgeTelemetry.instance.withSpan('complex_operation', () async {
await complexBusinessLogic();
});
```

## 🔒 Privacy & Security

- **No PII by default**: Only collects technical telemetry and user-provided profile data
- **Local-first option**: Store data locally instead of sending to backend
- **Configurable**: Disable any monitoring component you don't need
- **Transparent**: Full control over what data is collected and sent

## 🐛 Troubleshooting

### Debug Information
```dart
// Enable detailed logging
await EdgeTelemetry.initialize(
debugMode: true,  // Shows all telemetry in console
// ... other config
);

// Check current status
print('Initialized: ${EdgeTelemetry.instance.isInitialized}');
print('Session: ${EdgeTelemetry.instance.currentSessionInfo}');
```

### Common Issues

**HTTP requests not being tracked:**
- Ensure EdgeTelemetry is initialized before any HTTP calls
- Don't set custom `HttpOverrides.global` after initialization

**Navigation not tracked:**
- Add `EdgeTelemetry.instance.navigationObserver` to `MaterialApp.navigatorObservers`

**Events not appearing in backend:**
- Check `debugMode: true` for console logs
- Verify endpoint URL and network connectivity

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