// test/unit/models/report_data_test.dart

import 'package:edge_telemetry_flutter/src/core/models/report_data.dart';
import 'package:edge_telemetry_flutter/src/core/models/telemetry_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Report Data Models', () {
    test('TelemetryEvent should serialize/deserialize correctly', () {
      // Create an event
      final event = TelemetryEvent(
        id: 'event_123',
        sessionId: 'session_456',
        eventName: 'button_clicked',
        timestamp: DateTime.now(),
        attributes: {'screen': 'home', 'button': 'login'},
        userId: 'user_789',
      );

      // Convert to JSON and back
      final json = event.toJson();
      final reconstructed = TelemetryEvent.fromJson(json);

      // Verify all fields match
      expect(reconstructed.id, event.id);
      expect(reconstructed.sessionId, event.sessionId);
      expect(reconstructed.eventName, event.eventName);
      expect(reconstructed.userId, event.userId);
      expect(reconstructed.attributes, event.attributes);
    });

    test('TelemetryMetric should serialize/deserialize correctly', () {
      // Create a metric
      final metric = TelemetryMetric(
        id: 'metric_123',
        sessionId: 'session_456',
        metricName: 'response_time',
        value: 125.5,
        timestamp: DateTime.now(),
        attributes: {'endpoint': '/api/users'},
        userId: 'user_789',
      );

      // Convert to JSON and back
      final json = metric.toJson();
      final reconstructed = TelemetryMetric.fromJson(json);

      // Verify all fields match
      expect(reconstructed.id, metric.id);
      expect(reconstructed.sessionId, metric.sessionId);
      expect(reconstructed.metricName, metric.metricName);
      expect(reconstructed.value, metric.value);
      expect(reconstructed.userId, metric.userId);
      expect(reconstructed.attributes, metric.attributes);
    });

    test('TelemetrySession should calculate duration correctly', () {
      final startTime = DateTime.now();
      final endTime = startTime.add(Duration(minutes: 30));

      final session = TelemetrySession(
        sessionId: 'session_123',
        startTime: startTime,
        endTime: endTime,
        userId: 'user_456',
        deviceAttributes: {'device.model': 'iPhone 15'},
        appAttributes: {'app.version': '1.0.0'},
      );

      // Verify duration calculation
      expect(session.duration, Duration(minutes: 30));

      // Test copyWith for ending session
      final endedSession = session.copyWith(endTime: DateTime.now());
      expect(endedSession.sessionId, session.sessionId);
      expect(endedSession.endTime, isNotNull);
    });
  });
}
