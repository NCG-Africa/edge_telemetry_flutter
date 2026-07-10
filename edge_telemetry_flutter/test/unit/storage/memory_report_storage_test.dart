// test/unit/storage/memory_report_storage_test.dart

import 'package:edge_telemetry_flutter/src/core/models/report_data.dart';
import 'package:edge_telemetry_flutter/src/core/models/telemetry_session.dart';
import 'package:edge_telemetry_flutter/src/storage/memory_report_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemoryReportStorage', () {
    late MemoryReportStorage storage;

    setUp(() async {
      storage = MemoryReportStorage();
      await storage.initialize();
    });

    tearDown(() async {
      await storage.dispose();
    });

    test('should store and retrieve events', () async {
      // Create test event
      final event = TelemetryEvent(
        id: 'test_event_1',
        sessionId: 'test_session',
        eventName: 'button_clicked',
        timestamp: DateTime.now(),
        attributes: {'screen': 'home'},
      );

      // Store event
      await storage.storeEvent(event);

      // Retrieve events
      final events = await storage.getEvents();

      expect(events.length, 1);
      expect(events.first.eventName, 'button_clicked');
      expect(events.first.attributes['screen'], 'home');
    });

    test('should store and retrieve metrics', () async {
      // Create test metric
      final metric = TelemetryMetric(
        id: 'test_metric_1',
        sessionId: 'test_session',
        metricName: 'response_time',
        value: 125.5,
        timestamp: DateTime.now(),
        attributes: {'endpoint': '/api/test'},
      );

      // Store metric
      await storage.storeMetric(metric);

      // Retrieve metrics
      final metrics = await storage.getMetrics();

      expect(metrics.length, 1);
      expect(metrics.first.metricName, 'response_time');
      expect(metrics.first.value, 125.5);
    });

    test('should filter events by time range', () async {
      final now = DateTime.now();
      final oneHourAgo = now.subtract(Duration(hours: 1));
      final twoHoursAgo = now.subtract(Duration(hours: 2));

      // Store events at different times
      await storage.storeEvent(TelemetryEvent(
        id: 'old_event',
        sessionId: 'session_1',
        eventName: 'old_event',
        timestamp: twoHoursAgo,
      ));

      await storage.storeEvent(TelemetryEvent(
        id: 'recent_event',
        sessionId: 'session_1',
        eventName: 'recent_event',
        timestamp: now,
      ));

      // Query events from last hour only
      final recentEvents = await storage.getEvents(
        startTime: oneHourAgo,
        endTime: now,
      );

      expect(recentEvents.length, 1);
      expect(recentEvents.first.eventName, 'recent_event');
    });

    test('should manage sessions correctly', () async {
      final session = TelemetrySession(
        sessionId: 'test_session_123',
        startTime: DateTime.now(),
        userId: 'test_user',
        deviceAttributes: {'device.model': 'Test Device'},
        appAttributes: {'app.version': '1.0.0'},
      );

      // Start session
      await storage.startSession(session);

      // End session
      await storage.endSession(session.sessionId);

      // Verify session was stored and ended
      final sessions = storage.getAllSessions();
      expect(sessions.length, 1);
      expect(sessions.first.sessionId, 'test_session_123');
      expect(sessions.first.endTime, isNotNull);
    });

    test('should provide storage statistics', () async {
      // Add some test data
      await storage.storeEvent(TelemetryEvent(
        id: 'event_1',
        sessionId: 'session_1',
        eventName: 'test_event',
        timestamp: DateTime.now(),
      ));

      await storage.storeMetric(TelemetryMetric(
        id: 'metric_1',
        sessionId: 'session_1',
        metricName: 'test_metric',
        value: 100.0,
        timestamp: DateTime.now(),
      ));

      // Check stats
      final stats = storage.getStats();
      expect(stats['events'], 1);
      expect(stats['metrics'], 1);
      expect(stats['sessions'], 0); // No sessions started yet
    });

    test('should cleanup old data', () async {
      final now = DateTime.now();
      final oldDate = now.subtract(Duration(days: 35));

      // Add old data
      await storage.storeEvent(TelemetryEvent(
        id: 'old_event',
        sessionId: 'session_1',
        eventName: 'old_event',
        timestamp: oldDate,
      ));

      // Add recent data
      await storage.storeEvent(TelemetryEvent(
        id: 'recent_event',
        sessionId: 'session_1',
        eventName: 'recent_event',
        timestamp: now,
      ));

      // Cleanup data older than 30 days
      await storage.cleanupData(olderThan: now.subtract(Duration(days: 30)));

      // Verify only recent data remains
      final events = await storage.getEvents();
      expect(events.length, 1);
      expect(events.first.eventName, 'recent_event');
    });
  });
}
