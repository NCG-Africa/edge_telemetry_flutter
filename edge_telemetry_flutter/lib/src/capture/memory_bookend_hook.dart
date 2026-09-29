// lib/src/capture/memory_bookend_hook.dart

import '../core/edge_event.dart';
import '../crash/native_crash_channel.dart';
import 'capture_hook.dart';

/// Memory at the two session bookends — **two items replacing sixty** (#91).
///
/// v2 sampled `ProcessInfo.currentRss` on a 10-second `Timer.periodic` and
/// emitted a `memory_usage` metric plus an off-cadence `memory_pressure` event,
/// ~58 items per session, into a time series nothing read. Health stops being a
/// time series here: a stream graduates when a named consumer needs it, and the
/// 30–60 s cadence traced to a coverage table, not a dashboard.
///
/// The metric itself survives because the schema's memory columns are Flutter's
/// and permanently null on the sibling SDK — deprecating it would darken the
/// family's only landing memory signal. What is corrected is the **quantity**:
/// Dart's resident-set reading is the wrong number on *both* platforms and the
/// two are not comparable. It under-reports against the phys-footprint iOS
/// jetsams on, and over-reports on Android where the shared engine library
/// inflates RSS. So the read is native (footprint / total PSS) and
/// `memory.source` puts the break on the wire rather than leaving a step change
/// in a chart for somebody to misread as a regression.
///
/// ## Why `paused` is the closing bookend and finalize is not
///
/// `session.finalized` is the honest *logical* end, but the overwhelmingly
/// common ending is the OS killing a backgrounded process — that session
/// finalizes on the **next launch**, backdated, from a persisted record, in a
/// process whose memory has nothing to do with it. Reading at `paused` is the
/// last instant the number is real, and on iOS it is the number jetsam decides
/// on. Once per session: a pause/resume round trip is not a new session.
///
// ponytail: the closing read fires at the FIRST pause of a session, and a
// session rotated in the foreground (the 30-minute idle rule) closes with no
// item at all — the `Collector` stamps session identity at `add`, so a read
// started after the rotation would land on the new session and misattribute
// the old one's memory. Ceiling: one item, not two, for a long multi-pause
// session and for a foreground rotation. The upgrade path is a session id
// carried on the item itself rather than merged from the snapshot; do it when
// a consumer asks for end-of-session memory specifically.
///
/// `Capture.health` is asked once, at construction in `TelemetryWiring` — this
/// hook is not re-gated per emission, so the budget governor cannot shed it
/// mid-session. Two items a session is not what a governor is for.
class MemoryBookendHook implements CaptureHook {
  /// The one native seam. Only `memory.used_bytes` / `memory.source` are read
  /// from its map here — the five fault-bundle keys it also returns are
  /// fatal-only, attached by the crash path, never by a bookend.
  final NativeCrashChannel channel;

  /// `Pipeline.flush`. The closing read is asynchronous — a platform-channel
  /// round trip — so it resolves *after* the lifecycle hook's own flush has
  /// already gone. Without a second flush the one item the pause exists to
  /// capture would sit in the buffer waiting for a resume that may never come.
  /// Null in tests, and at the opening bookend it is never called: a one-item
  /// POST at session start buys nothing.
  final void Function()? flush;

  MemoryBookendHook({required this.channel, this.flush});

  EventSink? _sink;
  bool _closed = false;

  @override
  DisposeHandle start(EventSink sink) {
    _sink = sink;
    // No read here: `SessionManager.recoverAndStart()` runs after the hooks are
    // started, so [onSessionStart] is what opens the pair — including for a
    // mid-session rotation, which a one-shot read at start would miss.
    return () => _sink = null;
  }

  /// Opening bookend. Bound to `SessionManager.onSessionStart`, so a rotation
  /// starts a fresh pair.
  void onSessionStart() {
    _closed = false;
    _read('session_start');
  }

  /// Closing bookend, at most once per session. Bound to the lifecycle hook's
  /// `paused` branch — but the read is a channel round trip, so it lands after
  /// that hook's own flush has already gone. Hence [flush] here: the one item
  /// the pause exists to capture must not wait for a resume that may never come.
  void onPaused() {
    if (_closed) return;
    _closed = true;
    _read('session_end').then((emitted) {
      if (emitted) flush?.call();
    });
  }

  /// Reads and emits; returns whether an item was actually added.
  Future<bool> _read(String phase) async {
    final state = await channel.readDeviceState();
    final bytes = double.tryParse(state['memory.used_bytes'] ?? '');
    // Nothing to report rather than a zero: a plugin-less platform has no
    // memory signal, and a false 0 is the one reading a chart cannot ignore.
    if (bytes == null) return false;
    _sink?.add(EdgeEvent.metric('memory_usage', bytes, attributes: {
      'memory.unit': 'bytes',
      // `footprint` (iOS) | `pss` (Android). v2's `process_info` value named
      // the *reader*; this names the **quantity**, which is the break that
      // needs to be legible. v2's companion `memory.type: rss` is gone with the
      // quantity it described.
      if (state['memory.source'] != null)
        'memory.source': state['memory.source']!,
      'memory.phase': phase,
    }));
    return true;
  }
}
