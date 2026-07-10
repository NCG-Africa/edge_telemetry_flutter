// lib/src/core/models/telemetry_session.dart

/// Represents a user session (from app start to app close)
class TelemetrySession {
  final String sessionId;
  final DateTime startTime;
  final DateTime? endTime;
  final String? userId;
  final Map<String, String> deviceAttributes;
  final Map<String, String> appAttributes;

  const TelemetrySession({
    required this.sessionId,
    required this.startTime,
    this.endTime,
    this.userId,
    this.deviceAttributes = const {},
    this.appAttributes = const {},
  });

  /// Calculate session duration
  Duration? get duration {
    if (endTime == null) return null;
    return endTime!.difference(startTime);
  }

  /// Create a copy with some fields updated (useful for ending sessions)
  TelemetrySession copyWith({
    String? sessionId,
    DateTime? startTime,
    DateTime? endTime,
    String? userId,
    Map<String, String>? deviceAttributes,
    Map<String, String>? appAttributes,
  }) {
    return TelemetrySession(
      sessionId: sessionId ?? this.sessionId,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      userId: userId ?? this.userId,
      deviceAttributes: deviceAttributes ?? this.deviceAttributes,
      appAttributes: appAttributes ?? this.appAttributes,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'duration': duration?.inMilliseconds,
        'userId': userId,
        'deviceAttributes': deviceAttributes,
        'appAttributes': appAttributes,
      };

  /// Create from JSON (from storage)
  factory TelemetrySession.fromJson(Map<String, dynamic> json) =>
      TelemetrySession(
        sessionId: json['sessionId'],
        startTime: DateTime.parse(json['startTime']),
        endTime:
            json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
        userId: json['userId'],
        deviceAttributes:
            Map<String, String>.from(json['deviceAttributes'] ?? {}),
        appAttributes: Map<String, String>.from(json['appAttributes'] ?? {}),
      );
}
