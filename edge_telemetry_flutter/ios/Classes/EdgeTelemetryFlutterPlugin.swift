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
public class EdgeTelemetryFlutterPlugin: NSObject, FlutterPlugin, MXMetricManagerSubscriber {
  private static let channelName = "edge_telemetry/native_crash"

  private let store = CrashStore()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = EdgeTelemetryFlutterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    MXMetricManager.shared.add(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "drainNativeCrashes":
      result(store.drain())
    default:
      result(FlutterMethodNotImplemented)
    }
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
