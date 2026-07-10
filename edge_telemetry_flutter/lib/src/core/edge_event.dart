// lib/src/core/edge_event.dart

/// Send priority for an [EdgeEvent].
///
/// - [batched]: buffered by the Pipeline and sent in a `type:"batch"` envelope.
/// - [immediate]: sent straight away, bypassing the batch (crash rail).
enum EventPriority { batched, immediate }

/// Internal, pre-enrichment event model handed from a capture hook or a facade
/// API call into the [Collector].
///
/// It carries the raw wire pieces (name/value/error) plus the un-enriched custom
/// attributes; the Collector folds in the [ContextManager] snapshot before the
/// Pipeline builds the wire map.
class EdgeEvent {
  /// Wire discriminator: `'event'`, `'metric'`, or `'error'`.
  final String type;

  /// Event or metric name (empty for errors).
  final String name;

  /// Metric value (metrics only).
  final double? value;

  /// The thrown object (errors only).
  final Object? error;

  /// Stack trace for the error (errors only).
  final StackTrace? stackTrace;

  /// Custom, un-enriched attributes supplied by the caller.
  final Map<String, String> attributes;

  final EventPriority priority;

  /// Whether this event bumps the session event/metric counters.
  ///
  /// Matches v1.5.2: only events that flowed through the public facade API
  /// (`trackEvent`/`trackMetric`) or the HTTP path bump counters; internal
  /// capture (nav/perf/network) and errors do not.
  final bool countsToSession;

  const EdgeEvent.event(
    this.name, {
    this.attributes = const {},
    this.countsToSession = false,
  })  : type = 'event',
        value = null,
        error = null,
        stackTrace = null,
        priority = EventPriority.batched;

  const EdgeEvent.metric(
    this.name,
    this.value, {
    this.attributes = const {},
    this.countsToSession = false,
  })  : type = 'metric',
        error = null,
        stackTrace = null,
        priority = EventPriority.batched;

  const EdgeEvent.error(
    this.error, {
    this.stackTrace,
    this.attributes = const {},
  })  : type = 'error',
        name = '',
        value = null,
        countsToSession = false,
        priority = EventPriority.immediate;
}
