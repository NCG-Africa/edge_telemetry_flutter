// lib/src/managers/event_tracker_impl.dart

import 'package:opentelemetry/api.dart';

import '../core/interfaces/event_tracker.dart';
import 'span_manager.dart';

/// Implementation of event tracking using OpenTelemetry spans
///
/// Creates short-lived spans for events and metrics, managing
/// the full lifecycle automatically
class EventTrackerImpl implements EventTracker {
  final SpanManager _spanManager;

  EventTrackerImpl(this._spanManager);

  @override
  void trackEvent(String eventName, {Map<String, String>? attributes}) {
    final span = _spanManager.createSpan('custom.event');

    // Prepare event attributes with timestamp
    final eventAttributes = {
      'event.name': eventName,
      'event.timestamp': DateTime.now().toIso8601String(),
      ...?attributes,
    };

    // Convert to OpenTelemetry attributes
    final otelAttributes = _createOpenTelemetryAttributes(eventAttributes);

    // Add the event to the span
    span.addEvent(eventName, attributes: otelAttributes);

    // End the span immediately
    _spanManager.endSpan(span);
  }

  @override
  void trackMetric(String metricName, double value,
      {Map<String, String>? attributes}) {
    // Track metrics as special events
    trackEvent('metric', attributes: {
      'metric.name': metricName,
      'metric.value': value.toString(),
      'metric.timestamp': DateTime.now().toIso8601String(),
      'metric.type': 'gauge', // Default metric type
      ...?attributes,
    });
  }

  @override
  void trackError(Object error,
      {StackTrace? stackTrace, Map<String, String>? attributes}) {
    final span = _spanManager.createSpan('error.occurred');

    try {
      // Set error status on span
      span.setStatus(StatusCode.error, error.toString());

      // Record the exception with stack trace (handle nullable stackTrace)
      if (error is Exception) {
        if (stackTrace != null) {
          span.recordException(error, stackTrace: stackTrace);
        } else {
          span.recordException(error);
        }
      } else {
        final exception = Exception(error.toString());
        if (stackTrace != null) {
          span.recordException(exception, stackTrace: stackTrace);
        } else {
          span.recordException(exception);
        }
      }

      // Add error event with additional context
      final errorAttributes = {
        'error.type': error.runtimeType.toString(),
        'error.message': error.toString(),
        'error.timestamp': DateTime.now().toIso8601String(),
        'error.has_stack_trace': stackTrace != null ? 'true' : 'false',
        // Include crash fingerprint if available
        if (attributes?['crash.fingerprint'] != null)
          'crash.fingerprint': attributes!['crash.fingerprint']!,
        // Include breadcrumbs if available
        if (attributes?['breadcrumbs'] != null)
          'breadcrumbs': attributes!['breadcrumbs']!,
        if (attributes?['crash.breadcrumb_count'] != null)
          'crash.breadcrumb_count': attributes!['crash.breadcrumb_count']!,
        ...?attributes,
      };

      final otelAttributes = _createOpenTelemetryAttributes(errorAttributes);
      span.addEvent('error.occurred', attributes: otelAttributes);
    } finally {
      _spanManager.endSpan(span);
    }
  }

  /// Convert string attributes to OpenTelemetry attributes
  List<Attribute> _createOpenTelemetryAttributes(
      Map<String, String> attributes) {
    return attributes.entries
        .map((entry) => Attribute.fromString(entry.key, entry.value))
        .toList();
  }
}
