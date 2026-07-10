# EdgeTelemetry Flutter

🚀 **Truly Automatic** Real User Monitoring (RUM) and telemetry package for Flutter applications. **Zero additional code required** - just initialize and everything is tracked automatically!

## ✨ Features

- 🌐 **Automatic HTTP Request Monitoring** - ALL network calls tracked automatically (URL, method, status, duration)
- 🚨 **Enhanced Crash & Error Reporting** - Global error handling with crash fingerprinting and breadcrumbs
- 📱 **Automatic Navigation Tracking** - Screen transitions and user journeys with breadcrumb context
- ⚡ **Automatic Performance Monitoring** - Frame drops, memory usage, app startup times
- 🔄 **Automatic Session Management** - User sessions with auto-generated IDs
- 👤 **User Context Management** - Associate telemetry with user profiles
- 🍞 **Crash Context Breadcrumbs** - Rich crash context with automatic navigation breadcrumbs
- 💾 **Offline Crash Storage** - Store crashes offline when network is unavailable
- 🔄 **Smart Crash Retry** - Intelligent retry mechanism with exponential backoff
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

### 🚨 Enhanced Crash & Error Reporting (Zero Setup Required)
```dart
// Any unhandled error anywhere in your app:
throw Exception('Something went wrong');

// Gets automatically tracked with:
// - Full stack trace with crash fingerprinting
// - Rich context via breadcrumbs (navigation, user actions)
// - User and session context
// - Device information
// - Offline storage with smart retry mechanism
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

  // 🎯 Monitoring Controls (all default to true)
  enableHttpMonitoring: true,        // Automatic HTTP request tracking
  enableCrashReporting: true,        // Automatic crash & error reporting
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

runApp(MyApp());
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
  endpoint: 'https://your-backend.com/api/telemetry',
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

### 🔄 Crash Fingerprinting & Grouping
```dart
// Crashes are automatically fingerprinted for grouping similar issues
// Fingerprint format: ErrorType_MessageHash_StackFrameHash
// Example: "Exception_-1234567890_987654321"

// JSON crash report includes:
{
  "type": "error",
  "fingerprint": "Exception_-1234567890_987654321",
  "breadcrumbs": "[{\"message\":\"Navigated to /checkout\",\"category\":\"navigation\"}]",
  "attributes": {
    "crash.fingerprint": "Exception_-1234567890_987654321",
    "crash.breadcrumb_count": "5"
  }
}
```

### 💾 Offline Crash Storage & Retry
```dart
// Crashes are automatically stored offline when network is unavailable
// Smart retry mechanism with exponential backoff (1min → 2min → 4min → 1hr)
// Max 3 retry attempts before cleanup
// Automatic retry on network restoration

// Manual retry control (usually not needed)
final retryResults = await EdgeTelemetry.instance.forceRetryStoredCrashes();
print('Retry results: ${retryResults['success']} successful, ${retryResults['failure']} failed');
```

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
  endpoint: 'https://your-backend.com/api/telemetry',
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