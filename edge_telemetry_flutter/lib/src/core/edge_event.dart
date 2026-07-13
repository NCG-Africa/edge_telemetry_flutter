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

  /// The single source of truth for the `app.crash` wire shape.
  ///
  /// Every Dart error path (facade `trackError`, the auto-installed
  /// `FlutterError.onError` / `PlatformDispatcher.onError` / isolate handlers,
  /// and the SDK's own capture-hook self-diagnostics) funnels through here, so
  /// they all produce one immediate `app.crash` event with **unprefixed** keys
  /// (`message`, `stacktrace`, `exception_type`, `cause`, `is_fatal`) — the
  /// backend `rum_crash_events` extractors read these verbatim. `cause` is a
  /// clean fatal/non-fatal taxonomy (all Dart errors are `Error`/non-fatal); the
  /// specific handler goes in the secondary `crash.source`. The client never
  /// sends `crash_hash`/`severity`/`breadcrumbs` — the server derives those.
  factory EdgeEvent.error(
    Object error, {
    StackTrace? stackTrace,
    String? source,
    Map<String, String>? attributes,
  }) =>
      EdgeEvent._crash({
        'message': error.toString(),
        if (stackTrace != null) 'stacktrace': stackTrace.toString(),
        'exception_type': error.runtimeType.toString(),
        'cause': 'Error',
        'is_fatal': 'false',
        if (source != null) 'crash.source': source,
        ...?attributes,
      });

  const EdgeEvent._crash(this.attributes)
      : type = 'event',
        name = 'app.crash',
        value = null,
        error = null,
        stackTrace = null,
        countsToSession = false,
        priority = EventPriority.immediate;

  /// The session bookends (`session.started` / `session.finalized`). Immediate
  /// rail + bypass: they always reach the wire (never batched away, never
  /// sampled out — a sampled-out session must still bracket itself) and never
  /// bump the session counters. Attributes are carried verbatim (the finalize
  /// journey summary is pre-built by [SessionManager]).
  const EdgeEvent.session(this.name, this.attributes)
      : type = 'event',
        value = null,
        error = null,
        stackTrace = null,
        countsToSession = false,
        priority = EventPriority.immediate;
}
