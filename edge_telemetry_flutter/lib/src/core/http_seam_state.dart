// lib/src/core/http_seam_state.dart
//
// `sdk.http_seam_state` — which HTTP capture seams are **live** (#87).
//
// Its own file in `core/`, for the reason `clock_skew.dart` is: the `dart:io`
// seam is what installs one half and the wrapper seam is what sets the other,
// so a holder in either would make that file change for a second, unrelated
// reason. It also keeps the layer direction honest — `ContextManager` reads
// this, and a manager reaching into `capture/` for behaviour is the edge
// CLAUDE.md's "five layers, one direction" forbids.
//
// The key rides **every** item, not only HTTP rows, because the case worth
// knowing about is the session with no HTTP rows at all.
//
// It reports which seams are live, and pointedly **not** how much of the app's
// traffic they see. The SDK cannot know that: a `package:http` client it was
// never handed is indistinguishable from one that exists but is never used.
//
// The undetectable case — capture healthy, and every request going through a
// `cupertino_http`/`cronet_http` client nobody wrapped — is deliberately not
// papered over here. It has no client-side signature at all; it is named in
// the family change-request packet as a backend alert on sessions that
// finalize with `session.http_request_count == 0` while this key says a seam
// was live.

import 'dart:io';

import 'package:flutter/foundation.dart';

/// The `dart:io` global override is ours; no client wrapped.
const String kSeamStateOverrides = 'overrides';

/// The global is **not** ours — never installed, or replaced by the consumer
/// after init — but at least one client was wrapped.
const String kSeamStateWrapper = 'wrapper';

/// Both seams live.
const String kSeamStateBoth = 'both';

/// Neither. **Provable**, and the only honest thing to say when a consumer
/// assigned their own `HttpOverrides.global` after init and wrapped nothing.
const String kSeamStateBlind = 'blind';

/// The exact override instance the capture hook installed, held so the live
/// check is an identity compare rather than a type test: a consumer who
/// installs a *second* `TelemetryHttpOverrides` of their own has still taken
/// the seam away from the one this SDK is emitting through.
Object? _installedOverrides;

bool _clientWrapped = false;

/// Called by the `dart:io` seam when it installs or removes the global.
void recordOverridesSeam(Object? overrides) => _installedOverrides = overrides;

/// Called by the capture hook when it hands back a wrapped client, and cleared
/// when that hook is disposed — a disposed hook's clients emit nothing, so
/// leaving the flag set would make `blind` unprovable for the rest of the
/// process.
void recordClientWrapped({bool wrapped = true}) => _clientWrapped = wrapped;

/// Whether the `dart:io` override in force is the one we installed.
///
/// Evaluated on read, never latched: a consumer can sever the seam at any
/// instant by assigning `HttpOverrides.global`, and nothing notifies us. A
/// cached value would go on claiming a seam that died an hour ago.
bool get overridesSeamLive =>
    _installedOverrides != null &&
    identical(HttpOverrides.current, _installedOverrides);

/// The four values, resolved at the instant of the read.
///
/// **Deviation from #87, recorded deliberately:** the ticket calls this
/// "session-constant". It is session-*level* rather than per-request, but it is
/// not constant — the `dart:io` half can die mid-session, and a key that kept
/// claiming a dead seam would be exactly the coverage claim the same acceptance
/// criterion forbids. Under `kHoistBatchContext` a mid-session flip therefore
/// costs one extra Pipeline flush and a session can report two values; that is
/// the honest shape, and the flag is off.
String httpSeamState() {
  if (overridesSeamLive) {
    return _clientWrapped ? kSeamStateBoth : kSeamStateOverrides;
  }
  return _clientWrapped ? kSeamStateWrapper : kSeamStateBlind;
}

/// Forget both halves. Tests only — the state is process-wide, so one test's
/// wrapped client would otherwise ride every later test's snapshot.
@visibleForTesting
void resetHttpSeamState() {
  _installedOverrides = null;
  _clientWrapped = false;
}
