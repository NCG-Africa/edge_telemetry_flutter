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

/// `task.outcome` — three values, and a declared task reaches exactly one.
///
/// An enum rather than three string constants: `endTask` otherwise took two bare
/// `String`s, and swapping the task name for the outcome would have compiled. The
/// wire spelling is the member name, so there is nothing to keep in step.
enum TaskOutcome { completed, failed, abandoned }

/// `task.abandon_source` — **the gap, stated rather than hidden.**
///
/// [sessionEnd] is an in-process finalize: the session rotated on the 30-minute
/// idle rule with the task still open. There is no task TTL of its own — the
/// session idle window *is* the cap.
///
/// [launchRecovery] is the backdated finalize of a session whose process ended
/// without one. It **cannot say whether a crash caused the abandonment**: the
/// recovery finalize is emitted from `SessionManager.recoverAndStart`, and
/// `drainNativeCrashes()` runs after it in `initialize()`. Joining the two is the
/// backend's, on `session.id` — this value exists so a consumer reads "we do not
/// know" off the row instead of inferring it from a crash-free denominator.
enum TaskAbandonSource {
  sessionEnd('session_end'),
  launchRecovery('launch_recovery');

  const TaskAbandonSource(this.wire);

  /// The snake_case wire value — the member name is camelCase, and the wire is
  /// not renamed to suit Dart.
  final String wire;
}

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
  }) : type = 'event',
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
  }) : type = 'metric',
       occurredAt = null,
       error = null,
       stackTrace = null,
       bypassSampling = false,
       priority = EventPriority.batched;

  /// The `task.complete` wire shape — the terminal of a declared journey
  /// (#92, spec §12).
  ///
  /// **Terminal-only.** A task start costs no wire item: it is held in memory
  /// (and in the session record, so a killed process still reports it), and
  /// exactly one event is emitted when the task reaches an outcome. That is
  /// what makes the three-call API fire-and-forget — an unclosed start has no
  /// failure mode to leak, because it never allocated a wire item to leak.
  ///
  /// `span.duration_ms` is the **existing** span duration key, not a new
  /// `task.duration_ms`: time-on-task is a span duration and the family
  /// already has a column for one. Unlike `http.request` — which omits it on a
  /// root because the backend derives a root's duration from its children —
  /// this event **always** carries it. A task mints no root, so it can never
  /// be the row whose duration is derived, and it has no second duration key
  /// to fall back on: omitting it on an untraced task would lose the one
  /// measurement the signal exists for.
  ///
  /// [abandonSource] rides the abandoned outcome only. There is no slow/fast
  /// or Apdex band on the wire — banding is a query-time comparison against a
  /// per-target threshold, so it moves without a client release.
  ///
  /// **Subject to sampling, deliberately.** A sampled-out session drops its whole
  /// event stream coherently, and a declared task is developer-declared signal
  /// like `custom_event` — not part of the `essential` bypass set, which is
  /// v2's shipped set verbatim (crash, session bookends, profile update) and is
  /// not extended by this ticket. The `session.finalized` bookend still ships,
  /// which is the same asymmetry every sampled-out session already has.
  /// [sessionId] is set on the two **abandoned** legs and left to the context
  /// snapshot on the two closing ones. That is not two shapes for one event —
  /// it is one rule, that the row names the session whose ending it reports: a
  /// launch-recovered abandonment is emitted before `_beginSession`, so the
  /// snapshot holds no session at all and the row would otherwise arrive with an
  /// empty `session.id`, unjoinable to the session it is about. A `completeTask`
  /// belongs to whichever session the Collector is in when it lands, exactly
  /// like every other event the facade emits — including across the rotation
  /// that the close itself may trigger.
  factory EdgeEvent.task({
    required String name,
    required TaskOutcome outcome,
    required Duration duration,
    String? sessionId,
    TaskAbandonSource? abandonSource,
    Map<String, String> traceAttributes = const {},
  }) => EdgeEvent.event(
    'task.complete',
    attributes: {
      'task.name': name,
      'task.outcome': outcome.name,
      'span.duration_ms': duration.inMilliseconds.toString(),
      if (sessionId != null) 'session.id': sessionId,
      if (abandonSource != null) 'task.abandon_source': abandonSource.wire,
      ...traceAttributes,
    },
    // The whole point of the freeze: a task runs for minutes, so by the
    // time it terminates the ambient root is long gone or is an unrelated
    // tap. Its own frozen copy merges over a stripped snapshot — including
    // when the freeze found no open root, which is the empty case the axis
    // exists for.
    ownsTraceContext: true,
    // Deliberately **not** counted, on either leg. The abandoned leg is
    // emitted from the finalize path, where the counters are either already
    // frozen into the journey summary or belong to a session that ended in
    // a previous process — and one event may not count on one leg and not
    // the other.
  );

  /// The single source of truth for the Dart crash-family wire shape
  /// (catalogue `crash.yaml`, #127).
  ///
  /// Every Dart error path (facade `trackError`, the auto-installed
  /// `FlutterError.onError` / `PlatformDispatcher.onError` / isolate handlers,
  /// and the SDK's own capture-hook self-diagnostics) funnels through here.
  /// What a live `catch` reported is `app.error` (`error.cause: handled`); what
  /// one of the three auto-installed handlers caught is `app.crash`
  /// (`error.cause: unhandled_exception`). The handler token rides
  /// `error.source`. The client never sends `crash_hash` or `severity`, and
  /// mints **no error id and no fingerprint** — the server owns crash hashing.
  /// (The ring *does* ship, as `error.breadcrumbs`; the Collector attaches it.)
  ///
  /// Every Dart error **batches**, whichever name it carries: the process
  /// lives, so it earns the pipeline's retries and the offline queue (#90).
  /// Sampling bypass is kept: rail and sampling are orthogonal axes.
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
    final resolved =
        category ??
        (sdkInternal ? ErrorCategory.unknown : inferErrorCategory(error));
    final handled = _handled(source);
    return EdgeEvent._crash(handled ? 'app.error' : 'app.crash', {
      // The consumer's bag goes **first**, so every key below wins a
      // collision — they are read verbatim by the backend.
      ...?attributes,
      'error.message': error.toString(),
      if (stackTrace != null) 'error.stacktrace': stackTrace.toString(),
      'error.type': error.runtimeType.toString(),
      'error.cause': handled ? 'handled' : 'unhandled_exception',
      'error.category': resolved.wire,
      // The flag records where the value came from, so it ships only when it
      // came from somewhere: inference ran, or the developer declared. An
      // SDK-internal failure is neither — it is `unknown` by rule.
      if (!sdkInternal || category != null)
        'error.category_source':
            category != null ? kCategoryDeclared : kCategoryInferred,
      if (source != null) 'error.source': source,
    }, EventPriority.batched);
  }

  /// The native leg (spec #15 Phase 4, #29): a crash, ANR or hang the plugin
  /// drained from the previous process, onto the immediate rail.
  ///
  /// The plugins still write the pre-catalogue keys (`message`, `cause`,
  /// `crash.source`, ...) and payloads written by older builds sit on disk, so
  /// the catalogue spelling is applied here, on the one Dart path every native
  /// payload takes, rather than in three languages. `cause` picks the event:
  /// `ANR` → `app.anr`, `Hang` → `app.hang`, anything else → `app.crash`.
  /// `is_fatal` / `handled` are dropped: the event name says it.
  ///
  /// `error.category: unknown` is defaulted: an OS-reported crash carries no
  /// Dart type to classify, and it ships so a dashboard faceting on it covers
  /// every crash-family row.
  factory EdgeEvent.nativeCrash(Map<String, String> payload) {
    final attributes = <String, String>{
      'error.category': ErrorCategory.unknown.wire,
    };
    for (final MapEntry(:key, :value) in payload.entries) {
      if (key == 'is_fatal' || key == 'handled') continue;
      if (key == 'cause') {
        attributes['error.cause'] = _nativeCauses[value] ?? 'native_crash';
      } else {
        attributes[_nativeKeys[key] ?? key] = value;
      }
    }
    attributes['error.cause'] ??= 'native_crash';
    return EdgeEvent._crash(
      switch (attributes['error.cause']) {
        'anr' => 'app.anr',
        'hang' => 'app.hang',
        _ => 'app.crash',
      },
      Map.unmodifiable(attributes),
      EventPriority.immediate,
    );
  }

  /// Plugin key → catalogue key. `sdk.native_capture_tier` is a pre-4.0
  /// payload on disk: `sdk.*` is envelope-only (R1), so it moves unprefixed.
  static const Map<String, String> _nativeKeys = {
    'message': 'error.message',
    'stacktrace': 'error.stacktrace',
    'exception_type': 'error.type',
    'crash.source': 'error.source',
    'device.power_save_mode': 'device.power_save',
    'device.thermal_state': 'device.thermal_status',
    'sdk.native_capture_tier': 'native_capture_tier',
  };

  static const Map<String, String> _nativeCauses = {
    'NativeCrash': 'native_crash',
    'ANR': 'anr',
    'Hang': 'hang',
  };

  /// Whether the app kept running *because someone caught this*. The three
  /// auto-installed handlers catch what nobody else did, so they are unhandled;
  /// `trackError` and the SDK's own self-diagnostics are a live `catch`.
  ///
  /// The set is exactly the source tokens the facade emits. A fourth handler
  /// added later — a `runZonedGuarded` bridge being the obvious one — belongs
  /// here in the same commit, or its uncaught errors report as handled.
  static bool _handled(String? source) =>
      !const {
        'flutter_error',
        'platform_dispatcher',
        'isolate',
      }.contains(source);

  /// The rail is chosen by fatality and nothing else. A native crash, ANR or
  /// hang takes the immediate rail; a Dart error batches.
  EdgeEvent._crash(this.name, this.attributes, this.priority)
    : type = 'event',
      occurredAt = null,
      // The consumer's extra `trackError` attributes are merged into the
      // same map as the `error.*` keys. One flag cannot split them, so the
      // whole bag stays the SDK's — the safe half to be wrong about.
      consumerAttributes = false,
      // A crash mints no span and freezes nothing — it inherits the ambient
      // keys, which is exactly the attribution the action id already gives.
      ownsTraceContext = false,
      value = null,
      error = null,
      stackTrace = null,
      countsToSession = false,
      bypassSampling = true;

  /// The crash-family event names (catalogue `crash.yaml`).
  static const Set<String> crashEvents = {
    'app.crash',
    'app.error',
    'app.anr',
    'app.hang',
  };

  /// Whether this is a crash-family event.
  bool get isCrash => crashEvents.contains(name);

  /// A Dart error (`app.error`, or an unhandled Dart `app.crash`) — the item
  /// that batches, that the per-session error caps bound, and that ships the
  /// short breadcrumb slice. One getter, so the sites that ask cannot drift.
  bool get isNonFatalCrash => isCrash && priority == EventPriority.batched;

  /// The per-session cap's grouping key: exception type + top stack frame.
  ///
  /// **Client-local and never sent.** It groups occurrences of one fault for the
  /// cap and nothing else — the server owns crash hashing, so this is a counter
  /// key, not a fingerprint.
  String get crashDedupKey =>
      '${attributes['error.type']}|${_topFrame(attributes['error.stacktrace'])}';

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
