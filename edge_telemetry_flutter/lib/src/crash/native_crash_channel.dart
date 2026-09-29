// lib/src/crash/native_crash_channel.dart

import 'package:flutter/services.dart';

/// The one platform-channel seam for native crash capture (#10, spec #15 Phase 4)
/// and the native device-state read (#91).
///
/// Pull-only, two methods. Dart calls [drainNativeCrashes] once on init and
/// the native side returns every *new* `app.crash` payload the OS diagnostic
/// APIs surfaced since last launch (iOS MetricKit, Android
/// `ApplicationExitInfo` + `UncaughtExceptionHandler`). There is no push and no
/// streaming — a crashing process can't call back into Dart, so a next-launch
/// pull is the only model that works. [readDeviceState] is the same shape for a
/// different reason: there is no cadence and no observer to push from, because
/// device health is no longer a time series (#91).
///
/// **One channel, not two.** A second channel string would have cost nothing;
/// the expensive thing is the three-language lockstep surface, and that is paid
/// once per *method*, not once per channel.
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
/// All values arrive as strings.
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

  /// Read the device's current state natively, as a flat string map.
  ///
  /// Two call sites, both session bookends (`MemoryBookendHook`), and **no
  /// cache**: a cached reading of a value the point of which is that it changes
  /// is a reading of the wrong moment, and two reads per session is not a cost
  /// worth a staleness bug.
  ///
  /// ## Contract
  ///
  /// | key                      | meaning                               | example     |
  /// |--------------------------|---------------------------------------|-------------|
  /// | `device.battery_level`   | integer percent, 0–100                | `"87"`      |
  /// | `device.battery_charging`| `"true"` / `"false"`                  | `"false"`   |
  /// | `device.power_save_mode` | `"true"` / `"false"`                  | `"true"`    |
  /// | `device.thermal_state`   | `nominal`/`fair`/`serious`/`critical` | `"fair"`    |
  /// | `device.orientation`     | `portrait` / `landscape`              | `"portrait"`|
  /// | `memory.used_bytes`      | footprint (iOS) / total PSS (Android) | `"14237696"`|
  /// | `memory.source`          | `footprint` / `pss`                   | `"pss"`     |
  ///
  /// The first five are the **fault bundle** — the same five keys the Android
  /// uncaught-exception handler reads off the dying thread and writes into its
  /// crash payload, from this same native reader. They are read here too
  /// because the reader is one function on each platform; what makes them a
  /// fatal-only *signal* is that only the crash path attaches them to an item.
  ///
  /// **An unavailable key is omitted, never sentinelled.** No `-1`, no
  /// `"unknown"`: a battery level of `-1` is a number a dashboard will happily
  /// average. Orientation on iOS is omitted while the device is face-up or the
  /// orientation is not yet known, thermal state is omitted below Android 10,
  /// and a missing plugin means an **empty map** rather than a throw — so a
  /// platform with no registered handler degrades to no health signal, not to a
  /// failed init.
  Future<Map<String, String>> readDeviceState() async {
    try {
      final raw =
          await _channel.invokeMapMethod<String, dynamic>('readDeviceState');
      if (raw == null) return const {};
      return raw.map((k, v) => MapEntry(k, '$v'));
    } on MissingPluginException {
      return const {};
    }
  }
}
