// lib/main.dart - Clean implementation using your package

import 'package:edge_telemetry_flutter/edge_telemetry_flutter.dart';
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize your clean telemetry package
  await EdgeTelemetry.initialize(
    endpoint: 'http://localhost:3000/telemetry',  // JSON endpoint (not OpenTelemetry)
    serviceName: 'edge-telemetry-demo',
    debugMode: true,
    useJsonFormat: true,  // Explicitly enable JSON format
  );

  // Set user context (optional)
  EdgeTelemetry.instance.setUserProfile(
    email: 'demo@example.com',
    name: 'Demo User',
  );

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EdgeTelemetry Demo',
      // Add automatic navigation tracking
      navigatorObservers: [EdgeTelemetry.instance.navigationObserver],
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('EdgeTelemetry Demo'),
        backgroundColor: Colors.blue,
      ),
      body: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'EdgeTelemetry Package Demo',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: _testCustomEvent,
              child: Text('Track Custom Event'),
            ),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testMetric,
              child: Text('Track Custom Metric'),
            ),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testNetworkOperation,
              child: Text('Test Network Operation'),
            ),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testError,
              child: Text('Test Error Tracking'),
            ),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testCrashReporting,
              child: Text('🧪 Test Crash Reporting'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            ),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testConnectivity,
              child: Text('🧪 Test Connectivity'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            ),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => SecondScreen()),
                );
              },
              child: Text('Navigate to Second Screen'),
            ),
          ],
        ),
      ),
    );
  }

  void _testCustomEvent() {
    EdgeTelemetry.instance.trackEvent('demo.button_clicked', attributes: {
      'button.type': 'custom_event',
      'screen.name': 'home',
    });
  }

  void _testMetric() {
    EdgeTelemetry.instance
        .trackMetric('demo.response_time', 125.5, attributes: {
      'metric.category': 'performance',
      'endpoint': '/api/demo',
    });
  }

  Future<void> _testNetworkOperation() async {
    await EdgeTelemetry.instance.withNetworkSpan(
      'demo_api_call',
      'https://api.example.com/demo',
      'GET',
      () async {
        // Simulate network request
        await Future.delayed(Duration(milliseconds: 500));
        return 'Demo Response';
      },
      attributes: {
        'api.version': 'v1',
        'request.timeout': '5000',
      },
    );
  }

  void _testError() {
    try {
      throw Exception('Demo error for testing');
    } catch (error, stackTrace) {
      EdgeTelemetry.instance
          .trackError(error, stackTrace: stackTrace, attributes: {
        'error.context': 'demo_testing',
        'error.user_triggered': 'true',
      });
    }
  }

  void _testCrashReporting() {
    EdgeTelemetry.instance.testCrashReporting(
      customMessage: 'Manual crash test from demo app'
    );
  }

  void _testConnectivity() {
    EdgeTelemetry.instance.testConnectivity();
  }
}

class SecondScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Second Screen'),
        backgroundColor: Colors.green,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Second Screen',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                EdgeTelemetry.instance
                    .trackEvent('demo.second_screen_action', attributes: {
                  'action.type': 'button_click',
                  'screen.name': 'second',
                });
              },
              child: Text('Track Action on Second Screen'),
            ),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }
}
