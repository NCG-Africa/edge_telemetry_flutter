// lib/src/managers/span_manager.dart

import 'package:opentelemetry/api.dart';

/// Manages OpenTelemetry span lifecycle and attribute enrichment
///
/// Handles creating spans with automatic attribute injection,
/// user context management, and span lifecycle operations
class SpanManager {
  final Tracer _tracer;
  final Map<String, String> _globalAttributes;
  final Map<String, String> _userAttributes = {};

  SpanManager(this._tracer, this._globalAttributes);

  /// Set user context that will be added to all subsequent spans
  void setUser({
    required String userId,
    String? email,
    String? name,
    Map<String, String>? customAttributes,
  }) {
    _userAttributes.clear();
    _userAttributes.addAll({
      'user.id': userId,
      if (email != null) 'user.email': email,
      if (name != null) 'user.name': name,
      ...?customAttributes,
    });
  }

  /// Clear user context
  void clearUser() {
    _userAttributes.clear();
  }

  /// Get current user attributes (NEW: Public getter)
  Map<String, String> get userAttributes => Map.unmodifiable(_userAttributes);

  /// Get user ID if available (NEW: Convenience getter)
  String? get userId => _userAttributes['user.id'];

  /// Create a new span with automatic attribute enrichment
  ///
  /// Combines global attributes, user attributes, and custom attributes
  /// into a single span with all context information
  Span createSpan(String name, {Map<String, String>? attributes}) {
    final span = _tracer.startSpan(name);

    // Combine all attributes
    final allAttributes = {
      ..._globalAttributes,
      ..._userAttributes,
      'span.name': name,
      'span.start_time': DateTime.now().toIso8601String(),
      ...?attributes,
    };

    // Set attributes on the span
    for (final entry in allAttributes.entries) {
      span.setAttribute(Attribute.fromString(entry.key, entry.value));
    }

    return span;
  }

  /// End a span with optional success/error status
  void endSpan(Span span, {bool? success, String? errorMessage}) {
    // Set final attributes
    span.setAttribute(Attribute.fromString(
      'span.end_time',
      DateTime.now().toIso8601String(),
    ));

    // Set status if specified
    if (success == true) {
      span.setStatus(StatusCode.ok);
    } else if (success == false || errorMessage != null) {
      span.setStatus(StatusCode.error, errorMessage ?? 'Operation failed');
    }

    span.end();
  }

  /// Execute a function within a span with automatic lifecycle management
  ///
  /// Creates a span, executes the operation, and handles success/error
  /// states automatically with proper OpenTelemetry conventions
  Future<T> withSpan<T>(
    String spanName,
    Future<T> Function() operation, {
    Map<String, String>? attributes,
  }) async {
    final stopwatch = Stopwatch()..start();
    final span = createSpan(spanName, attributes: attributes);

    try {
      final result = await operation();

      // Add timing information
      stopwatch.stop();
      span.setAttribute(Attribute.fromString(
        'operation.duration_ms',
        stopwatch.elapsedMilliseconds.toString(),
      ));

      endSpan(span, success: true);
      return result;
    } catch (error, stackTrace) {
      // Add error timing information
      stopwatch.stop();
      span.setAttribute(Attribute.fromString(
        'operation.duration_ms',
        stopwatch.elapsedMilliseconds.toString(),
      ));

      // Record the exception
      if (error is Exception) {
        span.recordException(error, stackTrace: stackTrace);
      } else {
        span.recordException(Exception(error.toString()),
            stackTrace: stackTrace);
      }

      endSpan(span, success: false, errorMessage: error.toString());
      rethrow;
    }
  }

  /// Get current active span (if any)
  /// Note: OpenTelemetry Dart doesn't have Span.current(), so we return null
  Span? getCurrentSpan() {
    // OpenTelemetry Dart doesn't support getting current span
    // This is a limitation of the current implementation
    return null;
  }

  /// Add attributes to the current active span
  /// Note: Since we can't get current span, this is a no-op for now
  void addAttributesToCurrentSpan(Map<String, String> attributes) {
    // Cannot implement without Span.current() support
    // This is a known limitation in OpenTelemetry Dart
  }
}
