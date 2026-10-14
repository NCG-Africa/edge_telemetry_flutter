// lib/src/storage/memory_report_storage.dart

import '../core/interfaces/report_storage.dart';
import '../core/models/report_data.dart';
import '../core/models/telemetry_session.dart';

/// Simple in-memory storage for testing and development
///
/// This stores everything in memory - data is lost when app restarts
/// Perfect for getting the report system working before adding SQLite
class MemoryReportStorage implements ReportStorage {
  final List<TelemetryEvent> _events = [];
  final List<TelemetryMetric> _metrics = [];
  final Map<String, TelemetrySession> _sessions = {};

  bool _initialized = false;

  /// Logs are debugMode only: they carry session ids (SDK-003, #120).
  final bool debugMode;

  MemoryReportStorage({this.debugMode = false});

  void _log(String line) {
    if (debugMode) print(line);
  }

  @override
  Future<void> initialize() async {
    _initialized = true;
    _log('📦 Memory storage initialized');
  }

  @override
  Future<void> storeEvent(TelemetryEvent event) async {
    _ensureInitialized();
    _events.add(event);
    _log('📝 Stored event: ${event.eventName}');
  }

  @override
  Future<void> storeMetric(TelemetryMetric metric) async {
    _ensureInitialized();
    _metrics.add(metric);
    _log('📊 Stored metric: ${metric.metricName} = ${metric.value}');
  }

  @override
  Future<void> startSession(TelemetrySession session) async {
    _ensureInitialized();
    _sessions[session.sessionId] = session;
    _log('🚀 Started session: ${session.sessionId}');
  }

  @override
  Future<void> endSession(String sessionId) async {
    _ensureInitialized();
    final session = _sessions[sessionId];
    if (session != null) {
      _sessions[sessionId] = session.copyWith(endTime: DateTime.now());
      _log('🏁 Ended session: $sessionId');
    }
  }

  @override
  Future<List<TelemetryEvent>> getEvents({
    DateTime? startTime,
    DateTime? endTime,
    String? eventType,
    int? limit,
  }) async {
    _ensureInitialized();

    var filtered =
        _events.where((event) {
          // Filter by time range
          if (startTime != null && event.timestamp.isBefore(startTime)) {
            return false;
          }
          if (endTime != null && event.timestamp.isAfter(endTime)) {
            return false;
          }

          // Filter by event type
          if (eventType != null && event.eventName != eventType) {
            return false;
          }

          return true;
        }).toList();

    // Sort by timestamp (newest first)
    filtered.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Apply limit
    if (limit != null && filtered.length > limit) {
      filtered = filtered.take(limit).toList();
    }

    _log('🔍 Retrieved ${filtered.length} events');
    return filtered;
  }

  @override
  Future<List<TelemetryMetric>> getMetrics({
    DateTime? startTime,
    DateTime? endTime,
    String? metricName,
    int? limit,
  }) async {
    _ensureInitialized();

    var filtered =
        _metrics.where((metric) {
          // Filter by time range
          if (startTime != null && metric.timestamp.isBefore(startTime)) {
            return false;
          }
          if (endTime != null && metric.timestamp.isAfter(endTime)) {
            return false;
          }

          // Filter by metric name
          if (metricName != null && metric.metricName != metricName) {
            return false;
          }

          return true;
        }).toList();

    // Sort by timestamp (newest first)
    filtered.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Apply limit
    if (limit != null && filtered.length > limit) {
      filtered = filtered.take(limit).toList();
    }

    _log('🔍 Retrieved ${filtered.length} metrics');
    return filtered;
  }

  @override
  Future<void> cleanupData({DateTime? olderThan}) async {
    _ensureInitialized();

    final cutoffDate =
        olderThan ?? DateTime.now().subtract(const Duration(days: 30));

    // Remove old events
    final oldEventCount = _events.length;
    _events.removeWhere((event) => event.timestamp.isBefore(cutoffDate));

    // Remove old metrics
    final oldMetricCount = _metrics.length;
    _metrics.removeWhere((metric) => metric.timestamp.isBefore(cutoffDate));

    // Remove old sessions
    final oldSessionCount = _sessions.length;
    _sessions.removeWhere(
      (key, session) => session.startTime.isBefore(cutoffDate),
    );

    _log('🧹 Cleanup complete:');
    _log('  Events: $oldEventCount → ${_events.length}');
    _log('  Metrics: $oldMetricCount → ${_metrics.length}');
    _log('  Sessions: $oldSessionCount → ${_sessions.length}');
  }

  @override
  Future<void> dispose() async {
    _events.clear();
    _metrics.clear();
    _sessions.clear();
    _initialized = false;
    _log('🗑️ Memory storage disposed');
  }

  // Helper methods for debugging and testing

  /// Get current statistics
  Map<String, int> getStats() {
    return {
      'events': _events.length,
      'metrics': _metrics.length,
      'sessions': _sessions.length,
    };
  }

  /// Get all sessions (for debugging)
  List<TelemetrySession> getAllSessions() {
    return _sessions.values.toList();
  }

  /// Check if storage is initialized
  bool get isInitialized => _initialized;

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
        'Memory storage not initialized. Call initialize() first.',
      );
    }
  }
}
