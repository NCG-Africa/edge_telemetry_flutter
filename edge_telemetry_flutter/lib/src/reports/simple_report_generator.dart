// lib/src/reports/simple_report_generator.dart

import '../core/interfaces/report_generator.dart';
import '../core/interfaces/report_storage.dart';
import '../core/models/generated_report.dart';

/// Simple report generator that creates basic reports from stored data
class SimpleReportGenerator implements ReportGenerator {
  final ReportStorage _storage;

  SimpleReportGenerator(this._storage);

  @override
  Future<GeneratedReport> generateSummaryReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    final stopwatch = Stopwatch()..start();

    // Set default time range if not provided
    final end = endTime ?? DateTime.now();
    final start = startTime ?? end.subtract(Duration(hours: 24));

    // Get data from storage
    final events = await _storage.getEvents(startTime: start, endTime: end);
    final metrics = await _storage.getMetrics(startTime: start, endTime: end);

    // Count events by type
    final eventCounts = <String, int>{};
    for (final event in events) {
      eventCounts[event.eventName] = (eventCounts[event.eventName] ?? 0) + 1;
    }

    // Count metrics by type
    final metricCounts = <String, int>{};
    for (final metric in metrics) {
      metricCounts[metric.metricName] =
          (metricCounts[metric.metricName] ?? 0) + 1;
    }

    // Create report data
    final reportData = {
      'summary': {
        'period': {
          'start': start.toIso8601String(),
          'end': end.toIso8601String(),
          'duration_hours': end.difference(start).inHours,
        },
        'totals': {
          'events': events.length,
          'metrics': metrics.length,
        },
        'breakdown': {
          'events_by_type': eventCounts,
          'metrics_by_type': metricCounts,
        }
      },
      'raw_data': {
        'events': events.map((e) => e.toJson()).toList(),
        'metrics': metrics.map((m) => m.toJson()).toList(),
      }
    };

    stopwatch.stop();

    // Create metadata
    final metadata = ReportMetadata(
      totalEvents: events.length,
      totalMetrics: metrics.length,
      totalSessions: 1, // We'll improve this later
      generationTime: stopwatch.elapsed,
    );

    return GeneratedReport(
      reportId: _generateReportId('summary'),
      title: title ?? 'Summary Report',
      format: 'json',
      generatedAt: DateTime.now(),
      periodStart: start,
      periodEnd: end,
      data: reportData,
      metadata: metadata,
    );
  }

  @override
  Future<GeneratedReport> generatePerformanceReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    final stopwatch = Stopwatch()..start();

    final end = endTime ?? DateTime.now();
    final start = startTime ?? end.subtract(Duration(hours: 24));

    // Get performance-related metrics
    final metrics = await _storage.getMetrics(startTime: start, endTime: end);
    final performanceMetrics = metrics
        .where((m) =>
            m.metricName.contains('performance') ||
            m.metricName.contains('frame') ||
            m.metricName.contains('startup') ||
            m.metricName.contains('memory'))
        .toList();

    // Calculate performance stats
    final frameMetrics = performanceMetrics
        .where((m) => m.metricName.contains('frame'))
        .toList();
    final memoryMetrics = performanceMetrics
        .where((m) => m.metricName.contains('memory'))
        .toList();

    final reportData = {
      'performance_summary': {
        'period': {
          'start': start.toIso8601String(),
          'end': end.toIso8601String(),
        },
        'frame_performance': {
          'total_frames_tracked': frameMetrics.length,
          'average_frame_time': frameMetrics.isEmpty
              ? 0
              : frameMetrics.map((m) => m.value).reduce((a, b) => a + b) /
                  frameMetrics.length,
        },
        'memory_performance': {
          'memory_checks': memoryMetrics.length,
          'average_memory_usage': memoryMetrics.isEmpty
              ? 0
              : memoryMetrics.map((m) => m.value).reduce((a, b) => a + b) /
                  memoryMetrics.length,
        }
      },
      'detailed_metrics': performanceMetrics.map((m) => m.toJson()).toList(),
    };

    stopwatch.stop();

    final metadata = ReportMetadata(
      totalEvents: 0,
      totalMetrics: performanceMetrics.length,
      totalSessions: 1,
      generationTime: stopwatch.elapsed,
      additionalInfo: {
        'focus': 'performance',
        'frame_metrics_count': frameMetrics.length,
        'memory_metrics_count': memoryMetrics.length,
      },
    );

    return GeneratedReport(
      reportId: _generateReportId('performance'),
      title: title ?? 'Performance Report',
      format: 'json',
      generatedAt: DateTime.now(),
      periodStart: start,
      periodEnd: end,
      data: reportData,
      metadata: metadata,
    );
  }

  @override
  Future<GeneratedReport> generateUserBehaviorReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  }) async {
    final stopwatch = Stopwatch()..start();

    final end = endTime ?? DateTime.now();
    final start = startTime ?? end.subtract(Duration(hours: 24));

    // Get user behavior events
    final events = await _storage.getEvents(startTime: start, endTime: end);
    final navigationEvents = events
        .where((e) =>
            e.eventName.contains('navigation') ||
            e.eventName.contains('screen') ||
            e.eventName.contains('route'))
        .toList();

    // Analyze user actions
    final userActions = events
        .where((e) =>
            e.eventName.contains('button') ||
            e.eventName.contains('click') ||
            e.eventName.contains('tap'))
        .toList();

    final reportData = {
      'user_behavior_summary': {
        'period': {
          'start': start.toIso8601String(),
          'end': end.toIso8601String(),
        },
        'navigation': {
          'total_navigation_events': navigationEvents.length,
          'screens_visited': _extractUniqueScreens(navigationEvents),
        },
        'interactions': {
          'total_user_actions': userActions.length,
          'action_types': _countActionTypes(userActions),
        }
      },
      'detailed_events': events.map((e) => e.toJson()).toList(),
    };

    stopwatch.stop();

    final metadata = ReportMetadata(
      totalEvents: events.length,
      totalMetrics: 0,
      totalSessions: 1,
      generationTime: stopwatch.elapsed,
      additionalInfo: {
        'focus': 'user_behavior',
        'navigation_events': navigationEvents.length,
        'user_actions': userActions.length,
      },
    );

    return GeneratedReport(
      reportId: _generateReportId('user_behavior'),
      title: title ?? 'User Behavior Report',
      format: 'json',
      generatedAt: DateTime.now(),
      periodStart: start,
      periodEnd: end,
      data: reportData,
      metadata: metadata,
    );
  }

  // Helper methods

  String _generateReportId(String type) {
    return 'report_${type}_${DateTime.now().millisecondsSinceEpoch}';
  }

  List<String> _extractUniqueScreens(List<dynamic> navigationEvents) {
    final screens = <String>{};
    for (final event in navigationEvents) {
      if (event.attributes.containsKey('screen.name')) {
        screens.add(event.attributes['screen.name']!);
      }
      if (event.attributes.containsKey('navigation.to')) {
        screens.add(event.attributes['navigation.to']!);
      }
    }
    return screens.toList();
  }

  Map<String, int> _countActionTypes(List<dynamic> userActions) {
    final counts = <String, int>{};
    for (final action in userActions) {
      final actionType = action.attributes['action.type'] ?? 'unknown';
      counts[actionType] = (counts[actionType] ?? 0) + 1;
    }
    return counts;
  }
}
