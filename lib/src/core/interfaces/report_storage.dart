// lib/src/core/interfaces/report_storage.dart

import '../models/report_data.dart';
import '../models/telemetry_session.dart';

/// Interface for storing and retrieving telemetry data for reporting
///
/// Simple contract: store data, retrieve data, clean up data
abstract class ReportStorage {
  /// Initialize storage (create database, tables, etc.)
  Future<void> initialize();

  /// Store telemetry data points
  Future<void> storeEvent(TelemetryEvent event);
  Future<void> storeMetric(TelemetryMetric metric);

  /// Session management (track user sessions)
  Future<void> startSession(TelemetrySession session);
  Future<void> endSession(String sessionId);

  /// Retrieve data for reports (simple queries)
  Future<List<TelemetryEvent>> getEvents({
    DateTime? startTime,
    DateTime? endTime,
    String? eventType,
    int? limit,
  });

  Future<List<TelemetryMetric>> getMetrics({
    DateTime? startTime,
    DateTime? endTime,
    String? metricName,
    int? limit,
  });

  /// Cleanup old data (privacy and storage management)
  Future<void> cleanupData({DateTime? olderThan});

  /// Close storage connection
  Future<void> dispose();
}
