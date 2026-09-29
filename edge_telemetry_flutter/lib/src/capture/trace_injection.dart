// lib/src/capture/trace_injection.dart
//
// The propagation half of §5 (#86). Flutter **joins** a live, shipped contract
// — Android and React Native already feed the Go services this header — rather
// than designing one. So every value here is conformed, not derived: the
// header format, the allowlist matching rule, and the outcome vocabulary.
//
// Nothing in this file emits, buffers or sends. It answers one question per
// request — what header, and what trace keys on the event describing it — and
// the `dart:io` wrapper does both halves from the one answer, which is what
// makes the wire and the row agree by construction.

import '../managers/identity_format.dart';
import '../managers/trace_manager.dart';

/// The one propagation header. **W3C `traceparent` only** — no `tracestate`,
/// no B3, no baggage. One header read, one header written.
const String kTraceparentHeader = 'traceparent';

// ==================== THE FIVE OUTCOME RUNGS ====================
//
// `traceparent.outcome`, on `http.request` only. Three mutually incompatible
// vocabularies already exist in the family (the live `edge_db` enum, Android's
// shipped set, RN's shipped set), so Flutter speaks **Android's set minus
// `injected_unwired`** and mints no fourth dialect.
//
// **Absence is the contract's own member: absent = not traced.** The SDK's own
// upload carries no outcome key at all, and neither does a request that never
// reached a socket. There is no sixth value.
//
// `injected_unwired` is Android's sixth rung and is **provably unreachable
// here**. It means "the request tag is absent and the carrier null" — the
// interceptor was never wired, yet the request still happens and is still
// observable, so it needs a value saying so. Flutter's nearest analogue is a
// client that bypasses `HttpOverrides` entirely (`cupertino_http`,
// `cronet_http`, `grpc`, http2); those are not *partially* visible, they are
// **totally invisible** — no wrapper, no event, no attribute map to stamp an
// outcome onto. The rung has no carrier. Flutter's own wrapper always holds the
// frozen context, so the "tag absent" state cannot arise.

/// The host was not on the allowlist. Ids are still stamped on the event —
/// **no header leaves the device**.
const String kOutcomeSkippedOffAllowlist = 'skipped_off_allowlist';

/// The host app had already set a valid `traceparent`. Its ids are mirrored,
/// its header is left untouched, and the **local `rum.action.id` survives** —
/// `trace.id` answers "which call chain" (theirs) and `rum.action.id` answers
/// "which user action" (ours), which is the sibling's shipped behaviour.
const String kOutcomeAdopted = 'adopted';

/// Injected under a live root frozen at the call instant.
const String kOutcomeInjectedAttributed = 'injected_attributed';

/// Context existed at freeze and is no longer valid at inject — the root aged
/// out, or (Flutter's extension of the same semantic class) the session rotated
/// underneath a request that was still in flight. Re-rooted parentless.
const String kOutcomeInjectedExpired = 'injected_expired';

/// Nothing was ambient at the freeze instant. Re-rooted parentless.
const String kOutcomeInjectedUnattributed = 'injected_unattributed';

/// `00-<32hex>-<16hex>-01`. Version `00`; **flags literally `01`**.
///
/// The set flag is the whole of #55 D6 in one character: there is no separate
/// trace sampling rate, the per-session roll is the only sampling decision, and
/// head-based sampling's entire mechanism is the *unset* flag. Flutter cannot
/// express "traced but unsampled" without diverging from a format two siblings
/// ship and the Go processor parses — and a partial trace is worse than none,
/// since nothing on the wire would separate "sampled out" from "the SDK forgot".
String formatTraceparent(String traceId, String spanId) =>
    '00-$traceId-$spanId-01';

/// Strict: version `00`, lowercase hex, and **neither id all-zero**.
///
/// A failed parse is an *overwrite*, never a pass-through: the Go processor
/// truncates a malformed id without validating it, and `edge_db`'s CHECK then
/// fails the `rum_http_requests` insert, which dead-letters the whole event.
/// Adopting a bad id would delete the row.
({String traceId, String spanId})? parseTraceparent(String? value) {
  if (value == null) return null;
  final m = _traceparent.firstMatch(value.trim());
  if (m == null) return null;
  final traceId = m.group(1)!;
  final spanId = m.group(2)!;
  if (_isZero(traceId) || _isZero(spanId)) return null;
  return (traceId: traceId, spanId: spanId);
}

final RegExp _traceparent =
    RegExp(r'^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$');

bool _isZero(String id) => !id.codeUnits.any((c) => c != 0x30);

/// Android's matching rule verbatim: **exact host, or a dot-anchored suffix of
/// at least two labels**. `.example.com` matches `api.example.com` and never
/// `api.example.com.evil.com`; `.com` matches nothing.
///
/// An empty [allowlist] means **dark** — inject nowhere. That is the shipped
/// default on both siblings and it is the data-leak control: the header carries
/// internal trace topology, and a consumer's auth-token destination has no
/// business receiving it.
bool hostAllowed(String host, List<String> allowlist) {
  final h = host.toLowerCase();
  for (final raw in allowlist) {
    final entry = raw.toLowerCase().trim();
    if (entry.isEmpty) continue;
    if (!entry.startsWith('.')) {
      if (h == entry) return true;
      continue;
    }
    // ponytail: labels counted off the entry, not the host — the anchor is what
    // must be specific. `.com` is one label and matches nothing.
    if (entry.split('.').where((s) => s.isNotEmpty).length < 2) continue;
    if (h.endsWith(entry)) return true;
  }
  return false;
}

/// One request's answer: the trace keys its event carries, and the header to
/// send (null = send none).
///
/// Both come out of the same call, which is the load-bearing property: the
/// event describing a request and the header on that request are enriched from
/// one frozen copy, so the wire and the row cannot disagree.
class TraceDecision {
  const TraceDecision(this.attributes, this.header);

  final Map<String, String> attributes;
  final String? header;
}

/// Resolves the ladder for each request the `dart:io` wrapper sees.
///
/// Holds no per-request state — the frozen carrier lives on the request
/// wrapper, because that is the object whose lifetime *is* the request.
class TraceInjector {
  TraceInjector({
    required this.trace,
    this.allowlist = const [],
    this.debugMode = false,
  }) {
    if (debugMode && allowlist.isEmpty) {
      print('🔗 traceHostAllowlist is empty — no traceparent will be '
          'injected (dark by default)');
    }
  }

  final TraceManager trace;

  /// `TelemetryConfig.traceHostAllowlist`. `const []` = dark.
  final List<String> allowlist;

  final bool debugMode;

  /// **The freeze.** Called synchronously on entry to the request override,
  /// before the base client is awaited — that await measured 509 ms cold, and
  /// the host app may await again before `close()`. Reading ambient context at
  /// send time would silently reparent requests onto unrelated taps and produce
  /// data that looks entirely healthy.
  ///
  /// Null is the legal unattributed case, which is why the event carrying this
  /// must set `EdgeEvent.ownsTraceContext`.
  FrozenTrace? freeze() => trace.startChild();

  /// The ladder, evaluated once at `close()` — the last instant before bytes
  /// leave, and the only instant at which the consumer's own headers are
  /// visible.
  ///
  /// Outcomes describe the state at **freeze** time, not send time; the one
  /// value decided here is [kOutcomeInjectedExpired], which is precisely the
  /// finding that freeze-time state has since stopped being valid.
  TraceDecision resolve({
    required Uri url,
    required String? inbound,
    required FrozenTrace? frozen,
  }) {
    // Rung 1. Off-allowlist: ids are stamped locally so the request is still
    // correlatable inside the session, and nothing is propagated.
    if (!hostAllowed(url.host, allowlist)) {
      return TraceDecision(
        {
          ...(frozen ?? _requestRoot()).attributes,
          'traceparent.outcome': kOutcomeSkippedOffAllowlist,
        },
        null,
      );
    }

    // Rung 2. The host app is already tracing: mirror its ids, leave its header
    // alone, keep our action root. `parent.span.id` is omitted — the request is
    // root-shaped inside their trace.
    final adopted = parseTraceparent(inbound);
    if (adopted != null) {
      return TraceDecision({
        'trace.id': adopted.traceId,
        'span.id': adopted.spanId,
        if (frozen != null) ...{
          'rum.action.id': frozen.actionId,
          'trace.root_type': frozen.rootType.name,
        },
        'traceparent.outcome': kOutcomeAdopted,
      }, null);
    }

    // Rungs 3-5. We are the root. A trace never spans a session, so the frozen
    // session id is compared against the live one — one string compare on a
    // path already comparing hosts. "Mostly true" is a worse property for a
    // backend join than false.
    final FrozenTrace carrier;
    final String outcome;
    if (frozen == null) {
      carrier = _requestRoot();
      outcome = kOutcomeInjectedUnattributed;
    } else if (frozen.sessionId != trace.session.currentSessionId) {
      carrier = _requestRoot();
      outcome = kOutcomeInjectedExpired;
    } else {
      carrier = frozen;
      outcome = kOutcomeInjectedAttributed;
    }
    return TraceDecision(
      {...carrier.attributes, 'traceparent.outcome': outcome},
      formatTraceparent(carrier.traceId, carrier.spanId),
    );
  }

  /// A parentless `request` root: the request is its own root, so it mints a
  /// trace and a span and carries no `parent.span.id`.
  ///
  /// Deliberately **not** minted through [TraceManager.mint] — this root is not
  /// ambient (nothing else should hang off it) and it is not a user action, so
  /// it must not bump `session.action_count`.
  FrozenTrace _requestRoot() => FrozenTrace(
        traceId: secureHex32(),
        spanId: secureHex16(),
        parentSpanId: null,
        rootType: TraceRootType.request,
        sessionId: trace.session.currentSessionId,
      );
}
