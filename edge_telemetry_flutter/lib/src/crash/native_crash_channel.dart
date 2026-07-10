// lib/src/crash/native_crash_channel.dart

import 'package:flutter/services.dart';

/// The one platform-channel seam for native crash capture (#10, spec #15 Phase 4).
///
/// Pull-only, single method: Dart calls [drainNativeCrashes] once on init and
/// the native side returns every *new* `app.crash` payload the OS diagnostic
/// APIs surfaced since last launch (iOS MetricKit, Android
/// `ApplicationExitInfo` + `UncaughtExceptionHandler`). There is no push and no
/// streaming — a crashing process can't call back into Dart, so a next-launch
/// pull is the only model that works.
///
/// This class is the **published contract** the Phase-4 native plugin (Swift +
/// Kotlin) builds against in parallel. Until that plugin ships, there is no
/// method-call handler registered for the channel, so [drainNativeCrashes]
/// catches [MissingPluginException] and returns an empty list — a safe no-op.
///
/// ## Per-crash payload schema
///
/// Native returns a `List` of maps, one per crash, with these **unprefixed**
/// keys (the backend's `rum_crash_events` extractors read them verbatim; the
/// SDK never sends derived fields — server computes `crash_hash`,
/// `severity_level`, `breadcrumbs`):
///
/// | key              | meaning                                    | example                          |
/// |------------------|--------------------------------------------|----------------------------------|
/// | `message`        | human-readable summary                     | `"SIGSEGV"` / throwable message  |
/// | `stacktrace`     | **raw**, unsymbolicated frames (server symbolicates) | callStackTree / tombstone / ANR trace |
/// | `exception_type` | exception/signal class                     | `"EXC_BAD_ACCESS"` / `"NullPointerException"` |
/// | `cause`          | `NativeCrash` \| `ANR` \| `Hang`           | `"NativeCrash"`                  |
/// | `is_fatal`       | always `"true"` for native crashes         | `"true"`                         |
/// | `crash.source`   | `metrickit` \| `uncaught_handler` \| `app_exit_info` | `"metrickit"`          |
///
/// All values arrive as strings. See `docs/wayfinder/native-crash-capture.md` §4.
class NativeCrashChannel {
  /// The single channel name shared with the native plugin. Must stay in lock
  /// step with the Swift/Kotlin side — it is the contract.
  static const String channelName = 'edge_telemetry/native_crash';

  final MethodChannel _channel;

  NativeCrashChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Pull every native crash payload the OS surfaced since the last drain.
  ///
  /// Returns an empty list when no native plugin is registered (the current
  /// state until Phase 4) or when there are no new crashes.
  Future<List<Map<String, String>>> drainNativeCrashes() async {
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('drainNativeCrashes');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), '$v')))
          .toList(growable: false);
    } on MissingPluginException {
      // No native side wired yet — expected until Phase 4. Safe no-op.
      return const [];
    }
  }
}
