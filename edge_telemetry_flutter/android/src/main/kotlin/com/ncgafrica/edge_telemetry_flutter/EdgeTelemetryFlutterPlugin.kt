package com.ncgafrica.edge_telemetry_flutter

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.res.Configuration
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject
import java.io.File

/**
 * Android native crash capture (#28, spec #15 Phase 4).
 *
 * Two OS-diagnostic sources, no signal handlers and no watchdog threads:
 *  - **JVM `UncaughtExceptionHandler`** (all API levels): the throwable is
 *    written to a file as the process dies, then the previous handler runs.
 *    Read + cleared on the next launch's drain. `crash.source=uncaught_handler`.
 *  - **`ApplicationExitInfo`** (API 30+): on drain, the OS exit history is read
 *    and `REASON_CRASH_NATIVE`→`NativeCrash`, `REASON_ANR`→`ANR` are emitted.
 *    A persisted watermark (last-seen exit timestamp) stops re-reads across
 *    launches. `crash.source=app_exit_info`.
 *
 * `REASON_CRASH` (JVM) from `ApplicationExitInfo` is ignored — the live handler
 * above is the single source for JVM crashes, so we never double-report.
 *
 * Coverage is honest per device via `sdk.native_capture_tier`: `full` on API
 * 30+ (JVM + native + ANR), `jvm_only` below (native/ANR is a documented gap —
 * the OS-API-first trade for zero async-signal-safe native code).
 *
 * Stacks are raw/unsymbolicated — the server symbolicates. Payloads map to the
 * unprefixed `app.crash` schema published by `NativeCrashChannel` and drained
 * over `edge_telemetry/native_crash`; the Dart side is unchanged.
 *
 * ## Device state (#91)
 *
 * A second method, `readDeviceState`, serves the health signal on the same
 * channel — the expensive surface is the three-language lockstep, not the
 * channel string. Same five-key fault bundle is also read **inline in the
 * uncaught-exception handler**, off the dying thread, and written into the crash
 * payload: that is the only moment at which the state means anything about the
 * crash, and the only moment at which four binder reads are free. Nothing is
 * cached, nothing is observed, and no permission is required for any of it.
 */
class EdgeTelemetryFlutterPlugin : FlutterPlugin, MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var appContext: Context

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
    channel.setMethodCallHandler(this)
    installJvmHandler()
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "drainNativeCrashes" -> result.success(drain())
      // PSS is read from /proc/self/smaps — tens of milliseconds, and never on
      // the platform thread. `Debug.getMemoryInfo` rather than
      // `ActivityManager.getProcessMemoryInfo`, whose API-23 rate limit returns
      // the *previous* answer silently: a stale duplicate is worse than a slow
      // read, because only one of the two is visible.
      "readDeviceState" -> {
        val main = Handler(Looper.getMainLooper())
        Thread {
          val state = HashMap<String, String>(faultBundle()).apply { putAll(memory()) }
          main.post { result.success(state) }
        }.start()
      }
      else -> result.notImplemented()
    }
  }

  // --- JVM crashes (all API levels) ---------------------------------------

  /** Chain onto the default handler: persist, then let the process die. */
  private fun installJvmHandler() {
    val previous = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
      try {
        persistJvmCrash(throwable)
      } catch (_: Throwable) {
        // best-effort in a dying process — never swallow the crash itself
      }
      previous?.uncaughtException(thread, throwable)
    }
  }

  private fun persistJvmCrash(t: Throwable) {
    val dir = File(appContext.filesDir, CRASH_DIR).apply { mkdirs() }
    val json = JSONObject().apply {
      put("message", t.message ?: t.javaClass.name)
      put("stacktrace", t.stackTraceToString())
      put("exception_type", t.javaClass.name)
      put("cause", "NativeCrash")
      put("is_fatal", "true")
      put("crash.source", "uncaught_handler")
      put("sdk.native_capture_tier", tier())
      // The fault bundle, read here and nowhere else on the hot path: this
      // thread is already dying, so the binder calls cost the user nothing.
      // Memory is deliberately absent — the PSS read is far too slow to spend
      // on a process that is about to be gone, and it rides the bookends.
      for ((k, v) in faultBundle()) put(k, v)
    }
    // One file per crash → no read-modify-write while the process is dying.
    File(dir, "crash_${System.nanoTime()}.json").writeText(json.toString())
  }

  private fun readAndClearJvmCrashes(): List<Map<String, String>> {
    val files = File(appContext.filesDir, CRASH_DIR).listFiles() ?: return emptyList()
    val out = ArrayList<Map<String, String>>(files.size)
    for (f in files) {
      try {
        val obj = JSONObject(f.readText())
        val m = HashMap<String, String>()
        for (key in obj.keys()) m[key] = obj.getString(key)
        out.add(m)
      } catch (_: Throwable) {
        // corrupt/partial file — drop it
      }
      f.delete()
    }
    return out
  }

  // --- Native + ANR crashes (API 30+) -------------------------------------

  @RequiresApi(Build.VERSION_CODES.R)
  private fun readAppExitInfo(): List<Map<String, String>> {
    val am = appContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val reasons = am.getHistoricalProcessExitReasons(null, 0, 0)
    val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val watermark = prefs.getLong(KEY_WATERMARK, 0L)
    var newest = watermark
    val out = ArrayList<Map<String, String>>()
    for (info in reasons) {
      if (info.timestamp <= watermark) continue
      if (info.timestamp > newest) newest = info.timestamp
      val map = when (info.reason) {
        // REASON_CRASH (JVM) is deliberately skipped — the live handler owns it.
        ApplicationExitInfo.REASON_CRASH_NATIVE ->
          mapExit(info, cause = "NativeCrash", exceptionType = "REASON_CRASH_NATIVE")
        ApplicationExitInfo.REASON_ANR ->
          mapExit(info, cause = "ANR", exceptionType = "REASON_ANR")
        else -> null
      }
      if (map != null) out.add(map)
    }
    if (newest > watermark) prefs.edit().putLong(KEY_WATERMARK, newest).apply()
    return out
  }

  @RequiresApi(Build.VERSION_CODES.R)
  private fun mapExit(
    info: ApplicationExitInfo,
    cause: String,
    exceptionType: String,
  ): Map<String, String> = mapOf(
    "message" to (info.description ?: cause),
    "stacktrace" to readTrace(info),
    "exception_type" to exceptionType,
    "cause" to cause,
    "is_fatal" to "true",
    "crash.source" to "app_exit_info",
    "sdk.native_capture_tier" to tier(),
  )

  /** Raw tombstone (native) or ANR trace — the OS provides it for these reasons. */
  @RequiresApi(Build.VERSION_CODES.R)
  private fun readTrace(info: ApplicationExitInfo): String = try {
    info.traceInputStream?.bufferedReader()?.use { it.readText() } ?: ""
  } catch (_: Throwable) {
    ""
  }

  // --- Device state (#91) -------------------------------------------------

  /**
   * The five fault-bundle keys, each omitted when the platform cannot answer.
   * No sentinels: a battery level of -1 is a number a dashboard will average.
   *
   * Zero new permissions. `BatteryManager.getIntProperty`,
   * `PowerManager.isPowerSaveMode`, `currentThermalStatus` and the resource
   * configuration are all unprotected reads.
   */
  private fun faultBundle(): Map<String, String> {
    val out = HashMap<String, String>(5)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
      try {
        val bm = appContext.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (level in 0..100) out["device.battery_level"] = level.toString()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          out["device.battery_charging"] = bm.isCharging.toString()
        }
      } catch (_: Throwable) {
        // service missing or throwing on an OEM build — omit, never sentinel
      }
      try {
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        out["device.power_save_mode"] = pm.isPowerSaveMode.toString()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          out["device.thermal_state"] = thermalName(pm.currentThermalStatus)
        }
      } catch (_: Throwable) {
      }
    }
    try {
      out["device.orientation"] =
        if (appContext.resources.configuration.orientation ==
          Configuration.ORIENTATION_LANDSCAPE
        ) "landscape" else "portrait"
    } catch (_: Throwable) {
    }
    return out
  }

  /**
   * Thermal state is a **normalised string**, not the platform ordinal. Android
   * has seven statuses and iOS four, and they disagree on what the same integer
   * means — Android's 2 is MODERATE, iOS's 2 is serious. Shipping the ordinal
   * would author a vocabulary defect rather than inherit one. The four names are
   * iOS's, because they are the smaller vocabulary and every Android status maps
   * into them; everything past SEVERE is already the state where the OS throttles
   * and then kills, so it folds to `critical`.
   */
  private fun thermalName(status: Int): String = when (status) {
    PowerManager.THERMAL_STATUS_NONE -> "nominal"
    PowerManager.THERMAL_STATUS_LIGHT -> "fair"
    PowerManager.THERMAL_STATUS_MODERATE -> "serious"
    else -> "critical"
  }

  /**
   * Total PSS, in bytes. PSS rather than Dart's `ProcessInfo.currentRss`: RSS
   * counts every page of the shared Flutter engine library against this process,
   * so it over-reports on Android, and it is not the quantity the low-memory
   * killer ranks on either.
   */
  private fun memory(): Map<String, String> = try {
    val mi = Debug.MemoryInfo()
    Debug.getMemoryInfo(mi)
    mapOf(
      "memory.used_bytes" to (mi.totalPss.toLong() * 1024L).toString(),
      "memory.source" to "pss",
    )
  } catch (_: Throwable) {
    emptyMap()
  }

  // --- Drain --------------------------------------------------------------

  private fun drain(): List<Map<String, String>> {
    val out = ArrayList<Map<String, String>>()
    out.addAll(readAndClearJvmCrashes())
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) out.addAll(readAppExitInfo())
    return out
  }

  private fun tier(): String =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) "full" else "jvm_only"

  companion object {
    private const val CHANNEL_NAME = "edge_telemetry/native_crash"
    private const val PREFS = "edge_telemetry_native_crash"
    private const val KEY_WATERMARK = "aei_watermark"
    private const val CRASH_DIR = "edge_telemetry_crashes"
  }
}
