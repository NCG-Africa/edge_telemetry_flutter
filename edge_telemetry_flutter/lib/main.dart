// lib/main.dart - Clean implementation using your package

import 'package:edge_telemetry_flutter/edge_telemetry_flutter.dart';
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize your clean telemetry package
  await EdgeTelemetry.initialize(
    endpoint: 'http://localhost:4318/v1/traces',
    serviceName: 'edge-telemetry-demo',
    debugMode: true,
  );

  // Set user context (optional)
  EdgeTelemetry.instance.setUserProfile(
    email: 'demo@example.com',
    name: 'Demo User',
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EdgeTelemetry Demo',
      // Add automatic navigation tracking
      navigatorObservers: [EdgeTelemetry.instance.navigationObserver],
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EdgeTelemetry Demo'),
        backgroundColor: Colors.blue,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'EdgeTelemetry Package Demo',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _testCustomEvent,
              child: const Text('Track Custom Event'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testMetric,
              child: const Text('Track Custom Metric'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testNetworkOperation,
              child: const Text('Test Network Operation'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testError,
              child: const Text('Test Error Tracking'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SecondScreen()),
                );
              },
              child: const Text('Navigate to Second Screen'),
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
    // HTTP is now monitored automatically; this just simulates a request.
    await Future.delayed(const Duration(milliseconds: 500));
    EdgeTelemetry.instance.trackEvent('demo.network_operation', attributes: {
      'api.version': 'v1',
      'request.timeout': '5000',
    });
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
}

class SecondScreen extends StatelessWidget {
  const SecondScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Second Screen'),
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
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                EdgeTelemetry.instance
                    .trackEvent('demo.second_screen_action', attributes: {
                  'action.type': 'button_click',
                  'screen.name': 'second',
                });
              },
              child: const Text('Track Action on Second Screen'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }
}
