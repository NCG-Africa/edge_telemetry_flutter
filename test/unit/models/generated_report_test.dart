import 'dart:convert';

import 'package:edge_telemetry_flutter/edge_telemetry_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toJsonString is parseable JSON carrying the report', () {
    final at = DateTime.utc(2026, 10, 21);
    final report = GeneratedReport(
      reportId: 'r1',
      title: 'Summary Report',
      format: 'json',
      generatedAt: at,
      periodStart: at,
      periodEnd: at,
      data: {
        'totals': {'events': 2},
        'odd': at, // not JSON-encodable: falls back to toString()
      },
      metadata: const ReportMetadata(
        totalEvents: 2,
        totalMetrics: 0,
        totalSessions: 1,
        generationTime: Duration(milliseconds: 5),
      ),
    );

    final decoded = jsonDecode(report.toJsonString()) as Map<String, dynamic>;

    expect(decoded['reportId'], 'r1');
    expect(decoded['data']['totals']['events'], 2);
    expect(decoded['data']['odd'], at.toString());
  });
}
