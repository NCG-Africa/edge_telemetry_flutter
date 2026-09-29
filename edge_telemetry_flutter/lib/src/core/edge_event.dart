// lib/src/core/edge_event.dart

import '../crash/error_category.dart';

/// Send priority for an [EdgeEvent] — one of four orthogonal axes (the others
/// are [EdgeEvent.bypassSampling], [EdgeEvent.countsToSession] and
/// [EdgeEvent.ownsTraceContext]).
///
/// - [batched]: buffered by the Pipeline and sent in a `type:"batch"` envelope.
/// - [immediate]: sent straight away, bypassing the batch. Reserved for a
///   process that will not survive to the next flush — a **fatal** crash and
///   the session bookends. A non-fatal error batches (#90).
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
  /// `app.crash` and the `session.*` bookends are bypass. Rail and sampling are
  /// orthogonal: `user.profile.update` and a **non-fatal** `app.crash` are both
  /// batched-but-bypass — never time-critical, never sampled away.
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

  const EdgeEvent.event(
    this.name, {
    this.attributes = const {},
    this.countsToSession = false,
    this.bypassSampling = false,
    this.ownsTraceContext = false,
    this.consumerAttributes = false,
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
        error = null,
        stackTrace = null,
        bypassSampling = false,
        priority = EventPriority.batched;

  /// The single source of truth for the `app.crash` wire shape.
  ///
  /// Every Dart error path (facade `trackError`, the auto-installed
  /// `FlutterError.onError` / `PlatformDispatcher.onError` / isolate handlers,
  /// and the SDK's own capture-hook self-diagnostics) funnels through here, so
  /// they all produce one `app.crash` event with **unprefixed** keys
  /// (`message`, `stacktrace`, `exception_type`, `cause`, `is_fatal`) — the
  /// backend `rum_crash_events` extractors read these verbatim. `cause` is a
  /// clean fatal/non-fatal taxonomy (all Dart errors are `Error`/non-fatal); the
  /// specific handler goes in the secondary `crash.source`. The client never
  /// sends `crash_hash` or `severity`, and mints **no error id and no
  /// fingerprint** — the server owns crash hashing in both SDKs. (The ring
  /// *does* ship, as `crash.breadcrumbs`; the Collector attaches it.)
  ///
  /// Three v3 keys join them (#90): the dotted `error.category` taxonomy and its
  /// `error.category_source` honesty flag, plus `handled`, spelled as a string
  /// to match the shipped `is_fatal` rather than retyping a sibling's bool.
  ///
  /// Because every Dart error is non-fatal, this factory's product rides the
  /// **batch rail** — the immediate rail exists for a dying process, and a
  /// non-fatal's process lives. Sampling bypass is kept: rail and sampling are
  /// orthogonal axes.
  factory EdgeEvent.error(
    Object error, {
    StackTrace? stackTrace,
    String? source,
    Map<String, String>? attributes,
    ErrorCategory? category,
  }) {
    // An SDK-internal failure is exempt from inference: the category describes
    // what the *host app* did wrong, and the SDK's own `SocketException` is not
    // the host's network problem.
    final sdkInternal = source == kSdkCrashSource;
    final resolved = category ??
        (sdkInternal ? ErrorCategory.unknown : inferErrorCategory(error));
    return EdgeEvent._crash({
      // The consumer's bag goes **first**, so every key below wins a collision.
      // `is_fatal` now selects the *rail*, not just a value, so a stray consumer
      // key must not be able to route a non-fatal onto the rail reserved for a
      // dying process — and the rest are read verbatim by the backend.
      ...?attributes,
      'message': error.toString(),
      if (stackTrace != null) 'stacktrace': stackTrace.toString(),
      'exception_type': error.runtimeType.toString(),
      'cause': 'Error',
      'is_fatal': 'false',
      'handled': _handled(source).toString(),
      'error.category': resolved.wire,
      // The flag records where the value came from, so it ships only when it
      // came from somewhere: inference ran, or the developer declared. An
      // SDK-internal failure is neither — it is `unknown` by rule — and stamping
      // `inferred` on it would claim a guess that never happened.
      if (!sdkInternal || category != null)
        'error.category_source':
            category != null ? kCategoryDeclared : kCategoryInferred,
      if (source != null) 'crash.source': source,
    });
  }

  /// The native-crash leg of the same `app.crash` rail (spec #15 Phase 4, #29).
  ///
  /// The native plugin already built the unprefixed payload — `message`,
  /// `stacktrace`, `exception_type`, `cause` (`NativeCrash`/`ANR`/`Hang`),
  /// `is_fatal:"true"`, `crash.source`, and the `sdk.native_capture_tier`
  /// passthrough — so this factory carries the map verbatim onto the immediate
  /// rail (no `cause`/`is_fatal` synthesis; those come from the OS, not us).
  ///
  /// `handled:"false"` and `error.category:"unknown"` are defaulted here rather
  /// than added to the channel payload: an OS-reported crash is unhandled by
  /// definition and carries no Dart type to classify, so the Dart side states
  /// both without a three-language lockstep change. A payload that carries its
  /// own value wins.
  ///
  /// The category ships even though it is always `unknown`, so a dashboard
  /// faceting on `error.category` covers every `app.crash` rather than silently
  /// excluding the fatal half. `error.category_source` is **absent**: nothing
  /// was inferred and nothing declared. What a fatal *is* rides `cause`
  /// (`NativeCrash`/`ANR`/`Hang`), which discriminates it already.
  factory EdgeEvent.nativeCrash(Map<String, String> payload) =>
      EdgeEvent._crash(Map<String, String>.unmodifiable({
        'handled': 'false',
        'error.category': ErrorCategory.unknown.wire,
        ...payload,
      }));

  /// Whether the app kept running *because someone caught this*. The three
  /// auto-installed handlers catch what nobody else did, so they are unhandled;
  /// `trackError` and the SDK's own self-diagnostics are a live `catch`.
  ///
  /// The set is exactly the source tokens the facade emits. A fourth handler
  /// added later — a `runZonedGuarded` bridge being the obvious one — belongs
  /// here in the same commit, or its uncaught errors report as handled.
  static bool _handled(String? source) => !const {
        'flutter_error',
        'platform_dispatcher',
        'isolate'
      }.contains(source);

  /// The rail is chosen by fatality and nothing else. A fatal — every native
  /// crash, ANR and hang — takes the immediate rail because its process is
  /// dying and the pipeline will not get another tick. A non-fatal batches: its
  /// process lives, so the Pipeline and the offline queue can deliver it with
  /// retries instead of one attempt, and one error in a `build()` becomes items
  /// in a batch rather than N single-attempt POSTs.
  EdgeEvent._crash(this.attributes)
      : type = 'event',
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
        priority = attributes['is_fatal'] == 'false'
            ? EventPriority.batched
            : EventPriority.immediate;

  /// A non-fatal `app.crash` — the item that batches, that the per-session error
  /// caps bound, and that ships the short breadcrumb slice. One getter, so the
  /// sites that ask cannot drift apart on the spelling.
  bool get isNonFatalCrash =>
      name == 'app.crash' && attributes['is_fatal'] == 'false';

  /// The per-session cap's grouping key: exception type + top stack frame.
  ///
  /// **Client-local and never sent.** It groups occurrences of one fault for the
  /// cap and nothing else — the server owns crash hashing, so this is a counter
  /// key, not a fingerprint. An error with no stack folds every such error onto
  /// one key, which is the honest grouping: without a frame there is nothing to
  /// tell them apart by.
  String get crashDedupKey =>
      '${attributes['exception_type']}|${_topFrame(attributes['stacktrace'])}';

  /// The first non-blank stack line — the half of the key that separates two
  /// different `StateError`s.
  static String _topFrame(String? stacktrace) =>
      stacktrace
          ?.split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '') ??
      '';

  /// The session bookends (`session.started` / `session.finalized`). Immediate
  /// rail + bypass: they always reach the wire (never batched away, never
  /// sampled out — a sampled-out session must still bracket itself) and never
  /// bump the session counters. Attributes are carried verbatim (the finalize
  /// journey summary is pre-built by [SessionManager]).
  const EdgeEvent.session(this.name, this.attributes)
      : type = 'event',
        consumerAttributes = false,
        ownsTraceContext = false,
        value = null,
        error = null,
        stackTrace = null,
        countsToSession = false,
        bypassSampling = true,
        priority = EventPriority.immediate;
}
