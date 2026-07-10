// lib/src/core/interfaces/event_tracker.dart

/// Interface for tracking custom events and metrics
///
/// Implementations should handle:
/// - Custom event logging
/// - Metric collection
/// - Attribute management
/// - Event batching and delivery
abstract class EventTracker {
  /// Track a custom event with optional attributes
  ///
  /// [eventName] - Name of the event (e.g., 'user.login', 'button.clicked')
  /// [attributes] - Optional key-value pairs with additional context
  void trackEvent(String eventName, {Map<String, String>? attributes});

  /// Track a metric value with optional attributes
  ///
  /// [metricName] - Name of the metric (e.g., 'response_time', 'user_score')
  /// [value] - Numeric value of the metric
  /// [attributes] - Optional key-value pairs with additional context
  void trackMetric(String metricName, double value,
      {Map<String, String>? attributes});

  /// Track an error or exception
  ///
  /// [error] - The error/exception that occurred
  /// [stackTrace] - Optional stack trace for debugging
  /// [attributes] - Optional additional context
  void trackError(Object error,
      {StackTrace? stackTrace, Map<String, String>? attributes});

  /// Release resources (timers, connections, buffered events).
  ///
  /// Call once when telemetry is shutting down.
  void dispose();
}
