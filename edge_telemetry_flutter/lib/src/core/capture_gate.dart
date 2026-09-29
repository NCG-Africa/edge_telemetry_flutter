// lib/src/core/capture_gate.dart

import 'config/collection_tier.dart';
import 'config/telemetry_config.dart';

/// Per-session item ceilings the budget governor sheds on (#49 §3, policy
/// #64 D8). These are the *everything-on* rows, not the default row: a session
/// that reaches them despite the per-signal caps is pathological, and what is
/// worth keeping from a pathological session is the crash and the summary, not
/// a representative sample of the flood.
const int kDiagnosticShedCeiling = 250; // typical
const int kStandardShedCeiling = 1200; // heavy

/// The one thing a capture hook asks before it builds an attribute map.
///
/// Resolution is fixed once at construction (config: overrides → deprecated
/// booleans → tier default); only the governor moves at runtime. Gating happens
/// **here, at the hook** — gating at the Collector would build the map,
/// stringify the attributes, spend the CPU and discard the item, which is the
/// exact defect the tier model exists to avoid.
class CaptureGate {
  /// Config-resolved on/off per capture, precomputed so [allows] is a lookup.
  final Map<Capture, bool> _enabled;

  /// Bumped once per item the governor sheds, so every shed lands on the
  /// session's dropped-item counter. A capture the *consumer* turned off is not
  /// a drop — they chose that.
  final void Function()? onShed;

  CollectionTier? _shed;
  int _items = 0;

  CaptureGate(TelemetryConfig config, {this.onShed})
      : _enabled = {
          for (final c in Capture.values) c: config.capturesEnabled(c),
        };

  /// Whether [c] may run right now.
  bool allows(Capture c) {
    if (_enabled[c] != true) return false;
    if (_shed != null && c.tier.index >= _shed!.index) {
      onShed?.call();
      return false;
    }
    return true;
  }

  /// Count one item admitted to the wire. Crossing a ceiling sheds a **whole
  /// tier** — `diagnostic`, then `standard`, never `essential` — rather than
  /// ranking individual signals: the per-signal caps upstream are what keep a
  /// well-behaved app off the ceiling, and they are proportionate because they
  /// are signal-specific.
  void recordItem() {
    _items++;
    if (_items > kStandardShedCeiling) {
      _shed = CollectionTier.standard;
    } else if (_items > kDiagnosticShedCeiling) {
      _shed = CollectionTier.diagnostic;
    }
  }

  /// The budget is per session. Bound to `SessionManager.onSessionStart`, so a
  /// rotation starts a fresh allowance.
  void resetBudget() {
    _items = 0;
    _shed = null;
  }

  /// Lowest tier currently shed, or null when nothing is shed.
  CollectionTier? get shedTier => _shed;

  /// Items admitted this session.
  int get itemCount => _items;
}
