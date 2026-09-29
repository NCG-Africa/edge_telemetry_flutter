// lib/src/core/attribute_policy.dart
//
// The PII half of §3, at the one place every item passes: the Collector.
//
// PII partitions by **who chose the value**. The SDK redacts what it collected
// (the URL rules live in `capture/http_url.dart`, at the hook). This file is
// the other two thirds: it *caps what the developer named* and *hands the
// developer a hook over what they supplied*.

/// Distinct values kept per key per session before the cap bites.
const int kCardinalityCap = 50;

/// Distinct keys tracked per session. A bound on the tracker itself — key names
/// are developer-chosen and nothing stops a loop from minting one per item.
// ponytail: stop tracking past the bound rather than capping the new keys.
// Ceiling: a session that mints >100 attribute keys gets no cap on the ones it
// minted last. That session's cardinality problem is the key names, which no
// per-key cap addresses anyway.
const int kCardinalityKeyCap = 100;

/// What a value over the cap becomes. Deliberately unmistakable for data.
const String kCardinalitySentinel = '__over_cardinality__';

/// The SDK-minted keys that are **labels**, and so are capped alongside the
/// consumer's own.
///
/// An opt-in list, pointedly not an exemption list. Most of what the SDK mints
/// per item is unique by design — a span id, a timestamp, a duration, a byte
/// count — and a cap over all of it would sentinel the measurements the item
/// exists to carry from the 51st request onward. Inverting that would mean
/// every future emitter had to remember to exempt its new key, and the one
/// that forgot would fail silently. `http.url` is on the list because a REST
/// app really does mint unbounded paths, which is the whole reason path ids
/// are templated first. `screen.name` is on it for the same reason and is the
/// **only** guard on a parameterised route name (`/orders/8412`): those are
/// documented rather than sanitized, because the SDK cannot tell a path
/// segment the developer meant as a name from one they meant as an id, and
/// guessing would silently rename screens.
/// `navigation.to` / `navigation.from` carry the same route string as
/// `screen.name`, so the guard has to sit on all three or it guards one row
/// type out of two. `session.screen_journey` is deliberately *not* on the list:
/// it is a joined composite, so nearly every value is distinct and a cap would
/// sentinel it on the second navigation.
const Set<String> kCappedSdkKeys = {
  'http.url',
  'screen.name',
  'navigation.to',
  'navigation.from',
};

/// Runs over an item's **own** attributes — never the ~30-key context
/// snapshot, which would be 30 consumer callbacks per item on the UI isolate
/// for keys the SDK chose itself and already controls.
class AttributePolicy {
  /// The one redaction hook. Returns the value to send, or null to omit the
  /// key entirely. Consumer-supplied, so it runs over the developer-reachable
  /// half of the bag and nothing else.
  final String? Function(String key, String value)? redact;

  /// Bumped once per value replaced by the sentinel.
  final void Function()? onCapped;

  final Map<String, Set<String>> _seen = {};

  AttributePolicy({this.redact, this.onCapped});

  /// Apply the hook and the cap to [attributes], in place.
  ///
  /// [ownKeys] are the item's own attribute keys and [consumerSupplied] says
  /// whether the consumer chose them (`EdgeEvent.consumerAttributes`). When
  /// they did, both the hook and the cap run over all of them; when the SDK
  /// did, only [kCappedSdkKeys] is capped and the hook does not run at all —
  /// a hook returning null for a key it did not recognise would otherwise drop
  /// a span id, a session id or a stack trace.
  ///
  /// Redact first, then cap: the cap must count what actually leaves the
  /// device, or a hook that collapses a thousand ids to one token would still
  /// burn the allowance on the thousand.
  void apply(
    Map<String, String> attributes,
    Iterable<String> ownKeys, {
    required bool consumerSupplied,
  }) {
    for (final key in consumerSupplied ? ownKeys : kCappedSdkKeys) {
      final value = attributes[key];
      if (value == null) continue;

      if (consumerSupplied && redact != null) {
        final replacement = redact!(key, value);
        if (replacement == null) {
          attributes.remove(key);
          continue;
        }
        attributes[key] = replacement;
      }

      attributes[key] = _cap(key, attributes[key]!);
    }
  }

  String _cap(String key, String value) {
    final seen = _seen[key];
    if (seen == null) {
      if (_seen.length >= kCardinalityKeyCap) return value;
      _seen[key] = {value};
      return value;
    }
    if (seen.contains(value)) return value;
    if (seen.length >= kCardinalityCap) {
      onCapped?.call();
      return kCardinalitySentinel;
    }
    seen.add(value);
    return value;
  }

  /// The cap is per session, like the governor's budget and the action cap.
  /// Bound to `SessionManager.onSessionStart`.
  void reset() => _seen.clear();
}
