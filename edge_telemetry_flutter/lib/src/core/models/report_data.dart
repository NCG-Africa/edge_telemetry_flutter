// lib/src/core/models/report_data.dart

/// Represents a single telemetry event (button click, navigation, etc.)
class TelemetryEvent {
  final String id;
  final String sessionId;
  final String eventName;
  final DateTime timestamp;
  final Map<String, String> attributes;
  final String? userId;

  const TelemetryEvent({
    required this.id,
    required this.sessionId,
    required this.eventName,
    required this.timestamp,
    this.attributes = const {},
    this.userId,
  });

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'eventName': eventName,
        'timestamp': timestamp.toIso8601String(),
        'attributes': attributes,
        'userId': userId,
      };

  /// Create from JSON (from storage)
  factory TelemetryEvent.fromJson(Map<String, dynamic> json) => TelemetryEvent(
        id: json['id'],
        sessionId: json['sessionId'],
        eventName: json['eventName'],
        timestamp: DateTime.parse(json['timestamp']),
        attributes: Map<String, String>.from(json['attributes'] ?? {}),
        userId: json['userId'],
      );
}

/// Represents a single telemetry metric (response time, frame rate, etc.)
class TelemetryMetric {
  final String id;
  final String sessionId;
  final String metricName;
  final double value;
  final DateTime timestamp;
  final Map<String, String> attributes;
  final String? userId;

  const TelemetryMetric({
    required this.id,
    required this.sessionId,
    required this.metricName,
    required this.value,
    required this.timestamp,
    this.attributes = const {},
    this.userId,
  });

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'metricName': metricName,
        'value': value,
        'timestamp': timestamp.toIso8601String(),
        'attributes': attributes,
        'userId': userId,
      };

  /// Create from JSON (from storage)
  factory TelemetryMetric.fromJson(Map<String, dynamic> json) =>
      TelemetryMetric(
        id: json['id'],
        sessionId: json['sessionId'],
        metricName: json['metricName'],
        value: json['value'].toDouble(),
        timestamp: DateTime.parse(json['timestamp']),
        attributes: Map<String, String>.from(json['attributes'] ?? {}),
        userId: json['userId'],
      );
}
