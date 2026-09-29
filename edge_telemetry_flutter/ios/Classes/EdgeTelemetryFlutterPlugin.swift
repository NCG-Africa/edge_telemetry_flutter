import Flutter
import UIKit
import MetricKit

/// iOS native crash capture (#27, spec #15 Phase 4).
///
/// Pure MetricKit — no signal handlers, no watchdog threads. Subscribes to
/// `MXMetricManager` at plugin registration; MetricKit delivers crash/hang
/// diagnostic payloads on the *next launch* after the incident. Each payload is
/// mapped to the unprefixed `app.crash` schema (see NativeCrashChannel) and
/// cached to disk. Dart calls `drainNativeCrashes()` once on init to read and
/// clear the cache.
///
/// Cross-launch dedup: MetricKit delivers each payload exactly once, and the
/// drain reads-then-deletes the cache file — so an OS crash record is never
/// re-read across launches (the iOS equivalent of the Android watermark).
///
/// ## Device state (#91)
///
/// A second method, `readDeviceState`, serves the health signal on the same
/// channel — the expensive surface is the three-language lockstep, not the
/// channel string. Every read is unprotected and none is a required-reason API,
/// so this plugin's privacy manifest declares an **empty accessed-API array**.
///
/// Unlike Android, iOS attaches **no fault bundle to its fatal crashes**:
/// MetricKit hands the payload over on the next launch, in a different process,
/// with no record of what the battery or the thermal state was at the moment of
/// death. The keys are omitted rather than filled in from the live device —
/// this launch's state is not that crash's state, and a plausible wrong number
/// is worse than a missing one.
public class EdgeTelemetryFlutterPlugin: NSObject, FlutterPlugin, MXMetricManagerSubscriber {
  private static let channelName = "edge_telemetry/native_crash"

  private let store = CrashStore()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = EdgeTelemetryFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    MXMetricManager.shared.add(instance)
    // The only way to read a battery level on iOS, and it has to be on before
    // the first read or `batteryLevel` answers -1 forever. It is a mutation of
    // a singleton the host app also owns, so it is done once, at registration,
    // and never toggled back off — turning it off would break a host app that
    // switched it on for itself.
    UIDevice.current.isBatteryMonitoringEnabled = true
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "drainNativeCrashes":
      result(store.drain())
    case "readDeviceState":
      // Every read here is either a cheap property or one mach call; the UIKit
      // ones must be on the main thread, which is where a channel handler
      // already runs. No thread hop, and nothing worth caching.
      result(Self.deviceState())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Device state (#91)

  /// The fault bundle plus memory, as a flat string map. **A key the platform
  /// cannot answer is omitted, never sentinelled** — no -1 battery level, no
  /// "unknown" thermal state, because both are values a dashboard will happily
  /// aggregate.
  private static func deviceState() -> [String: String] {
    var out = faultBundle()
    if let bytes = memoryFootprint() {
      out["memory.used_bytes"] = String(bytes)
      out["memory.source"] = "footprint"
    }
    return out
  }

  private static func faultBundle() -> [String: String] {
    var out: [String: String] = [:]
    let device = UIDevice.current

    let level = device.batteryLevel  // -1 while unknown or monitoring is off
    if level >= 0 { out["device.battery_level"] = String(Int((level * 100).rounded())) }
    switch device.batteryState {
    case .charging, .full: out["device.battery_charging"] = "true"
    case .unplugged: out["device.battery_charging"] = "false"
    default: break  // .unknown — omit
    }

    let info = ProcessInfo.processInfo
    out["device.power_save_mode"] = info.isLowPowerModeEnabled ? "true" : "false"
    if let thermal = thermalName(info.thermalState) { out["device.thermal_state"] = thermal }

    // The *interface* orientation, not `UIDevice.orientation`: the latter reads
    // .unknown unless the host app asked for orientation notifications, and
    // reports face-up/face-down, which is not an orientation the UI has.
    if let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    {
      let orientation = scene.interfaceOrientation
      if orientation.isPortrait {
        out["device.orientation"] = "portrait"
      } else if orientation.isLandscape {
        out["device.orientation"] = "landscape"
      }
    }
    return out
  }

  /// Thermal state as a **normalised string**, never the platform ordinal:
  /// Android's 2 is MODERATE and iOS's 2 is serious, so the integer means two
  /// different things on the two halves of the same family. These four names are
  /// the canon; Android folds its seven statuses into them.
  private static func thermalName(_ state: ProcessInfo.ThermalState) -> String? {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return nil  // a future case is omitted, not guessed
    }
  }

  /// `phys_footprint` — the quantity jetsam actually kills on, and the reason
  /// Dart's `ProcessInfo.currentRss` was the wrong number here: RSS excludes
  /// the compressed and IOKit-mapped pages the footprint counts, so it
  /// under-reports against the limit that matters. Not a required-reason API.
  private static func memoryFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return nil }
    return UInt64(info.phys_footprint)
  }

  // MARK: MXMetricManagerSubscriber

  // Metrics payloads — not used here (crash capture only).
  public func didReceive(_ payloads: [MXMetricPayload]) {}

  public func didReceive(_ payloads: [MXDiagnosticPayload]) {
    var crashes: [[String: String]] = []
    for payload in payloads {
      for c in payload.crashDiagnostics ?? [] { crashes.append(Self.map(crash: c)) }
      for h in payload.hangDiagnostics ?? [] { crashes.append(Self.map(hang: h)) }
    }
    if !crashes.isEmpty { store.append(crashes) }
  }

  // MARK: Payload mapping (→ NativeCrashChannel schema, all-string values)

  private static func map(crash c: MXCrashDiagnostic) -> [String: String] {
    let exceptionType = c.exceptionType?.stringValue
      ?? c.signal?.stringValue
      ?? "unknown"
    var parts: [String] = []
    if let reason = c.terminationReason, !reason.isEmpty { parts.append(reason) }
    if let signal = c.signal?.stringValue { parts.append("signal \(signal)") }
    let message = parts.isEmpty ? "native crash" : parts.joined(separator: " ")
    return [
      "message": message,
      "stacktrace": stack(c.callStackTree),
      "exception_type": exceptionType,
      "cause": "NativeCrash",
      "is_fatal": "true",
      "crash.source": "metrickit",
    ]
  }

  private static func map(hang h: MXHangDiagnostic) -> [String: String] {
    let seconds = h.hangDuration.converted(to: .seconds).value
    return [
      "message": String(format: "app hang %.1fs", seconds),
      "stacktrace": stack(h.callStackTree),
      "exception_type": "MXHangDiagnostic",
      "cause": "Hang",
      "is_fatal": "true",
      "crash.source": "metrickit",
    ]
  }

  // Raw, unsymbolicated call-stack JSON — server symbolicates.
  private static func stack(_ tree: MXCallStackTree) -> String {
    String(data: tree.jsonRepresentation(), encoding: .utf8) ?? ""
  }
}

/// Disk-backed cache for crash payloads that arrive between launches.
/// One JSON array file in Application Support; append is read-modify-write,
/// drain is read-then-delete. A serial queue makes both atomic against the
/// MetricKit delivery thread.
private final class CrashStore {
  private let queue = DispatchQueue(label: "edge_telemetry.crash_store")

  private var fileURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("edge_telemetry_native_crashes.json")
  }

  func append(_ crashes: [[String: String]]) {
    queue.sync {
      var all = read()
      all.append(contentsOf: crashes)
      write(all)
    }
  }

  func drain() -> [[String: String]] {
    queue.sync {
      let all = read()
      try? FileManager.default.removeItem(at: fileURL)
      return all
    }
  }

  private func read() -> [[String: String]] {
    guard let data = try? Data(contentsOf: fileURL),
      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
    else { return [] }
    return json
  }

  private func write(_ crashes: [[String: String]]) {
    guard let data = try? JSONSerialization.data(withJSONObject: crashes) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
