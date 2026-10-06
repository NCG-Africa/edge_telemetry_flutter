// lib/src/core/clock_skew.dart
//
// The offset between the collector's clock and this device's — **recorded,
// never corrected** (#86, §5 D11).
//
// Its own file rather than a field on the transport or a line in the canon:
// the transport is what observes it and the envelope is what carries it, so a
// holder either side would make one of those two files change for a second,
// unrelated reason.

/// The collector's clock minus ours, in milliseconds. Null until the first
/// successful POST of the launch.
///
/// The collector's HTTP `Date` response header is a free server timestamp
/// already arriving on every successful POST, so one subtraction buys the
/// offset the backend needs to shift a session onto server time at query time.
/// Correcting client timestamps in place is rejected outright: it destroys
/// debuggability and breaks idempotent replay of offline batches, which by
/// design arrive hours or days late.
///
/// Process-wide for the same reason the gzip probe is — skew is a property of
/// the device's clock, not of a transport instance.
// ponytail: `Date` has one-second resolution and the estimate ignores round
// trip, so it is accurate to ~±1 s. That is two orders below the corrections
// it exists to expose; take a request-time midpoint the day sub-second skew
// matters.
int? recordedClockSkewMs;

/// Record the offset from a collector response's `Date` header. A null header
/// (or a response that never arrived) leaves the last estimate standing.
void recordClockSkew(DateTime? serverDate) {
  if (serverDate == null) return;
  recordedClockSkewMs = serverDate.difference(DateTime.now()).inMilliseconds;
}

/// Forget the recorded offset. Tests only — the value is process-wide, so one
/// test's skew would otherwise ride every later test's envelope.
void resetClockSkew() => recordedClockSkewMs = null;
