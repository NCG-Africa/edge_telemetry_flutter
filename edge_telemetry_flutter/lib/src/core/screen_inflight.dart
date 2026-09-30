// lib/src/core/screen_inflight.dart
//
// In-flight HTTP requests, counted per screen visit (#88 §7) — the one input
// the settled inference needs that the widget tree cannot give it.
//
// Module-level state, for exactly the reason `http_seam_state.dart` is
// module-level: the code that has to increment lives inside the wrappers
// `HttpOverrides.global` constructs, reached through two separate seams
// (`TelemetryHttpClient` and `CapturedClient`). A field would mean four
// constructors threading a dependency none of those classes is about, and the
// `dart:io` global is process-wide anyway.
//
// The screen id is **ambient**, which is what makes the inference cost no new
// machinery: a request claims the current screen at call entry — the same
// instant it freezes its trace context — and releases it at completion. The
// screen-load hook only has to watch the count.

import 'package:flutter/foundation.dart';

/// The screen visit that requests started *now* belong to. Set by the
/// screen-load hook on every screen entry, and only by it: when
/// `Capture.screenLoad` is off nothing sets this, every claim returns null and
/// the map below stays empty.
String? _currentScreenId;

/// In-flight count per screen visit id. An entry is removed when it reaches
/// zero, so an empty map means nothing is in flight anywhere.
final Map<String, int> _inFlight = {};

void Function(String screenId, int inFlight)? _listener;

/// Watch the count for every screen. One callback rather than a drained/busy
/// pair: the hook has to cancel its quiet window when a request *starts* just
/// as much as it has to arm one when the last one ends.
void bindScreenInflightListener(
  void Function(String screenId, int inFlight)? listener,
) => _listener = listener;

/// The screen a request entering the seam right now belongs to.
void setCurrentScreen(String? screenId) => _currentScreenId = screenId;

/// Claim the current screen for one request. Returns the id the matching
/// [endScreenRequest] must be given — captured, never re-read, because the
/// screen will have changed by the time the request completes.
String? beginScreenRequest() {
  final id = _currentScreenId;
  if (id == null) return null;
  final n = (_inFlight[id] ?? 0) + 1;
  _inFlight[id] = n;
  _listener?.call(id, n);
  return id;
}

/// Release one request's claim. A no-op for an unknown id, which is the normal
/// shape of a request that outlived its screen's terminal (see [forgetScreen]).
void endScreenRequest(String? screenId) {
  if (screenId == null) return;
  final n = (_inFlight[screenId] ?? 0) - 1;
  if (n <= 0) {
    _inFlight.remove(screenId);
  } else {
    _inFlight[screenId] = n;
  }
  _listener?.call(screenId, n < 0 ? 0 : n);
}

/// Requests still in flight for [screenId].
int inFlightForScreen(String? screenId) =>
    screenId == null ? 0 : (_inFlight[screenId] ?? 0);

/// Drop [screenId]'s entry outright.
///
// ponytail: this is what bounds the map. A response nobody drains never
// completes (already a broken consumer under `dart:io`), so its claim would
// otherwise be permanent. The screen-load hook forgets the id at its terminal
// — which the 10 s deadline guarantees always arrives — so the map holds at
// most the open screen. Ceiling: a stuck request's own count is simply lost,
// which is right, because the screen it was blocking is already resolved.
void forgetScreen(String? screenId) {
  if (screenId != null) _inFlight.remove(screenId);
}

/// Tests only — the state is process-wide, so one test's claims would
/// otherwise ride the next test's inference.
@visibleForTesting
void resetScreenInflight() {
  _currentScreenId = null;
  _inFlight.clear();
  _listener = null;
}
