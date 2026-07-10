// lib/src/core/models/generated_report.dart

/// Represents a generated report with metadata and data
class GeneratedReport {
  final String reportId;
  final String title;
  final String format; // 'json', 'text', etc.
  final DateTime generatedAt;
  final DateTime periodStart;
  final DateTime periodEnd;
  final Map<String, dynamic> data; // The actual report content
  final ReportMetadata metadata;

  const GeneratedReport({
    required this.reportId,
    required this.title,
    required this.format,
    required this.generatedAt,
    required this.periodStart,
    required this.periodEnd,
    required this.data,
    required this.metadata,
  });

  /// Convert entire report to JSON
  Map<String, dynamic> toJson() => {
        'reportId': reportId,
        'title': title,
        'format': format,
        'generatedAt': generatedAt.toIso8601String(),
        'periodStart': periodStart.toIso8601String(),
        'periodEnd': periodEnd.toIso8601String(),
        'metadata': metadata.toJson(),
        'data': data,
      };

  /// Get human-readable summary
  String getSummary() {
    return '''
Report: $title
Generated: ${generatedAt.toLocal()}
Period: ${periodStart.toLocal()} to ${periodEnd.toLocal()}
Events: ${metadata.totalEvents}
Metrics: ${metadata.totalMetrics}
Sessions: ${metadata.totalSessions}
''';
  }
}

/// Metadata about the report (stats and context)
class ReportMetadata {
  final int totalEvents;
  final int totalMetrics;
  final int totalSessions;
  final Duration generationTime;
  final Map<String, dynamic> additionalInfo;

  const ReportMetadata({
    required this.totalEvents,
    required this.totalMetrics,
    required this.totalSessions,
    required this.generationTime,
    this.additionalInfo = const {},
  });

  Map<String, dynamic> toJson() => {
        'totalEvents': totalEvents,
        'totalMetrics': totalMetrics,
        'totalSessions': totalSessions,
        'generationTime': generationTime.inMilliseconds,
        'additionalInfo': additionalInfo,
      };
}
