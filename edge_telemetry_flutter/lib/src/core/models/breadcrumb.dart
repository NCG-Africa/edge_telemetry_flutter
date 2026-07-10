// lib/src/core/models/breadcrumb.dart

/// Represents a breadcrumb entry for crash context tracking
class Breadcrumb {
  final String message;
  final String category;
  final BreadcrumbLevel level;
  final DateTime timestamp;
  final Map<String, String>? data;

  const Breadcrumb({
    required this.message,
    required this.category,
    required this.level,
    required this.timestamp,
    this.data,
  });

  /// Create breadcrumb from JSON
  factory Breadcrumb.fromJson(Map<String, dynamic> json) {
    return Breadcrumb(
      message: json['message'] as String,
      category: json['category'] as String,
      level: BreadcrumbLevel.values.firstWhere(
        (e) => e.name == json['level'],
        orElse: () => BreadcrumbLevel.info,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      data: json['data'] != null 
          ? Map<String, String>.from(json['data'] as Map)
          : null,
    );
  }

  /// Convert breadcrumb to JSON
  Map<String, dynamic> toJson() {
    return {
      'message': message,
      'category': category,
      'level': level.name,
      'timestamp': timestamp.toIso8601String(),
      if (data != null) 'data': data,
    };
  }

  @override
  String toString() {
    return 'Breadcrumb(message: $message, category: $category, level: ${level.name}, timestamp: $timestamp)';
  }
}

/// Breadcrumb severity levels
enum BreadcrumbLevel {
  debug,
  info,
  warning,
  error,
  critical,
}

/// Predefined breadcrumb categories
class BreadcrumbCategory {
  static const String navigation = 'navigation';
  static const String user = 'user';
  static const String system = 'system';
  static const String network = 'network';
  static const String ui = 'ui';
  static const String custom = 'custom';
}
