// lib/src/core/edge_event.dart

/// Send priority for an [EdgeEvent] — one of four orthogonal axes (the others
/// are [EdgeEvent.bypassSampling], [EdgeEvent.countsToSession] and
/// [EdgeEvent.ownsTraceContext]).
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

  /// Sampling axis, orthogonal to [priority]. When true the event bypasses the
  /// per-session sample gate (`session.sampled`) and always reaches the wire.
  ///
  /// `app.crash` and the `session.*` bookends are bypass (they ride the immediate
  /// rail too); `user.profile.update` is **batched-but-bypass** — an identity
  /// mutation that isn't time-critical but must never be sampled away.
  final bool bypassSampling;

  /// Whether this event bumps the session event/metric counters.
  ///
  /// Matches v1.5.2: only events that flowed through the public facade API
  /// (`trackEvent`/`trackMetric`) or the HTTP path bump counters; internal
  /// capture (nav/perf/network) and errors do not.
  final bool countsToSession;

  /// The fourth orthogonal axis, joining priority, sampling bypass and session
  /// counting: this item carries its **own** trace context, frozen at the
  /// moment it describes, so the Collector strips the ambient trace keys
  /// (`kAmbientTraceAttributes`) out of the snapshot before merging the item's
  /// attributes over the top.
  ///
  /// Set it on anything emitted materially later than the moment it describes —
  /// a request, a screen load, a task start — including when the freeze found
  /// *no* open root. That empty case is the whole reason the axis exists: an
  /// absent key cannot beat a present one in a spread, so without the strip a
  /// legally-unattributed request would inherit whatever tap happened while it
  /// was in flight.
  final bool ownsTraceContext;

  /// Whether the **consumer** chose this item's own attribute keys and values.
  ///
  /// Not a fifth behavioural axis — it is provenance, and it buys one thing:
  /// `AttributePolicy` acts on the consumer's half of the bag and leaves the
  /// SDK's alone. PII partitions by who chose the value, so the partition has
  /// to be recorded where the value enters.
  ///
  /// It defaults to **false**, which is the fail-safe direction. An SDK-minted
  /// attribute is often unique per item — a span id, a timestamp, a duration —
  /// and capping one at 50 distinct values per session would sentinel exactly
  /// the measurements the item exists to carry. A consumer key is the opposite:
  /// arbitrary, unbounded, and the thing the cap was built for.
  final bool consumerAttributes;

  /// When the thing this item describes actually happened, if that is not
  /// "now". The Collector stamps the wire `timestamp` from it.
  ///
  /// Not a fifth axis either — it is the same deferral [ownsTraceContext]
  /// exists for, seen from the time side. An item held back by a reservoir and
  /// emitted minutes later (`frame.summary`) would otherwise land on the wire
  /// at its flush instant, putting a ten-second window at the moment the app
  /// was backgrounded. The precedent is the OS-killed session, finalized and
  /// backdated on the next launch.
  final DateTime? occurredAt;

  const EdgeEvent.event(
    this.name, {
    this.attributes = const {},
    this.countsToSession = false,
    this.bypassSampling = false,
    this.ownsTraceContext = false,
    this.consumerAttributes = false,
    this.occurredAt,
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
    this.ownsTraceContext = false,
    this.consumerAttributes = false,
  })  : type = 'metric',
        occurredAt = null,
        error = null,
        stackTrace = null,
        bypassSampling = false,
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

  /// The native-crash leg of the same `app.crash` rail (spec #15 Phase 4, #29).
  ///
  /// The native plugin already built the unprefixed payload — `message`,
  /// `stacktrace`, `exception_type`, `cause` (`NativeCrash`/`ANR`/`Hang`),
  /// `is_fatal:"true"`, `crash.source`, and the `sdk.native_capture_tier`
  /// passthrough — so this factory carries the map verbatim onto the immediate
  /// rail (no `cause`/`is_fatal` synthesis; those come from the OS, not us).
  factory EdgeEvent.nativeCrash(Map<String, String> payload) =>
      EdgeEvent._crash(Map<String, String>.unmodifiable(payload));

  const EdgeEvent._crash(this.attributes)
      : type = 'event',
        occurredAt = null,
        // The consumer's extra `trackError` attributes are merged into the
        // same map as `message` / `stacktrace`, which the backend extractors
        // read verbatim. One flag cannot split them, so the whole bag stays
        // the SDK's — the safe half to be wrong about.
        consumerAttributes = false,
        // A crash mints no span and freezes nothing — it inherits the ambient
        // keys, which is exactly the attribution the action id already gives.
        ownsTraceContext = false,
        name = 'app.crash',
        value = null,
        error = null,
        stackTrace = null,
        countsToSession = false,
        bypassSampling = true,
        priority = EventPriority.immediate;

  /// The session bookends (`session.started` / `session.finalized`). Immediate
  /// rail + bypass: they always reach the wire (never batched away, never
  /// sampled out — a sampled-out session must still bracket itself) and never
  /// bump the session counters. Attributes are carried verbatim (the finalize
  /// journey summary is pre-built by [SessionManager]).
  const EdgeEvent.session(this.name, this.attributes)
      : type = 'event',
        occurredAt = null,
        consumerAttributes = false,
        ownsTraceContext = false,
        value = null,
        error = null,
        stackTrace = null,
        countsToSession = false,
        bypassSampling = true,
        priority = EventPriority.immediate;
}
