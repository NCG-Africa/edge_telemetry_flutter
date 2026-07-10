// lib/src/core/interfaces/report_generator.dart

import '../models/generated_report.dart';

/// Interface for generating telemetry reports
///
/// Simple contract: generate different types of reports from stored data
abstract class ReportGenerator {
  /// Generate a simple summary report
  Future<GeneratedReport> generateSummaryReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  });

  /// Generate a detailed performance report
  Future<GeneratedReport> generatePerformanceReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  });

  /// Generate a user behavior report
  Future<GeneratedReport> generateUserBehaviorReport({
    DateTime? startTime,
    DateTime? endTime,
    String? title,
  });
}
