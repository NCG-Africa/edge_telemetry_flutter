// lib/src/collectors/flutter_device_info_collector.dart

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/interfaces/device_info_collector.dart';
import '../managers/device_id_manager.dart';
import '../managers/identity_format.dart';

/// Flutter implementation of device information collector
///
/// Collects device, platform, and app information using Flutter plugins
class FlutterDeviceInfoCollector implements DeviceInfoCollector {
  /// Where the R9 fallback id is persisted — its own key, beside (not inside)
  /// the secure-storage device id it stands in for.
  static const String _fallbackKey = 'edge_telemetry_fallback_device_id';

  final DeviceIdManager _deviceIdManager;
  final Future<SharedPreferences> Function() _prefs;

  FlutterDeviceInfoCollector({
    DeviceIdManager? deviceIds,
    @visibleForTesting Future<SharedPreferences> Function()? prefs,
  }) : _deviceIdManager = deviceIds ?? DeviceIdManager(),
       _prefs = prefs ?? SharedPreferences.getInstance;

  @override
  Future<Map<String, String>> collectDeviceInfo() async {
    final attributes = <String, String>{};

    // Step 1: the device id, which is never absent (R9) — the envelope root
    // requires it and the collector 400s a batch without one (C6).
    try {
      attributes['device.id'] = await _deviceIdManager.getDeviceId();
    } catch (e) {
      print('⚠️ Device ID generation failed, using a fallback UUID: $e');
      attributes['device.id'] = await _fallbackDeviceId();
    }

    try {
      // Collect app information
      final packageInfo = await PackageInfo.fromPlatform();
      attributes.addAll({
        'app.name': packageInfo.appName,
        'app.version': packageInfo.version,
        'app.build_number': packageInfo.buildNumber,
        'app.package_name': packageInfo.packageName,
      });

      // device.platform = real OS, per item. `sdk.platform` is gone (R2) and
      // `sdk.version` rides the envelope's `sdk` block.
      attributes['device.platform'] = platformTag();
      attributes['device.platform_version'] = Platform.operatingSystemVersion;

      // Collect platform-specific device information
      await _collectPlatformSpecificInfo(attributes);
    } catch (e) {
      // If collection fails, add error info but continue
      attributes['device.info_error'] = e.toString();
    }

    return attributes;
  }

  /// A random UUIDv4 generated once and persisted under its own key; if
  /// storage fails too, one in-memory UUID for the rest of the process.
  Future<String> _fallbackDeviceId() async {
    try {
      final prefs = await _prefs();
      final stored = prefs.getString(_fallbackKey);
      if (stored != null) return stored;
      final id = uuidV4();
      if (await prefs.setString(_fallbackKey, id)) return id;
    } catch (e) {
      print('⚠️ Fallback device ID not persisted: $e');
    }
    return _inMemoryDeviceId ??= uuidV4();
  }

  /// Collect platform-specific device information
  Future<void> _collectPlatformSpecificInfo(
    Map<String, String> attributes,
  ) async {
    final deviceInfo = DeviceInfoPlugin();

    // Android and iOS only — on any other OS the facade never gets here (R16).
    if (Platform.isAndroid) {
      await _collectAndroidInfo(deviceInfo, attributes);
    } else if (Platform.isIOS) {
      await _collectIOSInfo(deviceInfo, attributes);
    }
  }

  /// Collect Android-specific information
  Future<void> _collectAndroidInfo(
    DeviceInfoPlugin deviceInfo,
    Map<String, String> attributes,
  ) async {
    try {
      final androidInfo = await deviceInfo.androidInfo;
      // `device.fingerprint` **stays**: it is OS build metadata
      // (`brand/product/device:release/id/incremental:type/tags`), identical
      // across every device on that build — not a per-device fingerprint. The
      // audit misread its own name.
      attributes.addAll({
        'device.model': androidInfo.model,
        'device.manufacturer': androidInfo.manufacturer,
        'device.brand': androidInfo.brand,
        'device.android_sdk': androidInfo.version.sdkInt.toString(),
        'device.android_release': androidInfo.version.release,
        'device.fingerprint': androidInfo.fingerprint,
        'device.hardware': androidInfo.hardware,
        'device.product': androidInfo.product,
      });
    } catch (e) {
      attributes['device.android_error'] = e.toString();
    }
  }

  /// Collect iOS-specific information
  Future<void> _collectIOSInfo(
    DeviceInfoPlugin deviceInfo,
    Map<String, String> attributes,
  ) async {
    try {
      final iosInfo = await deviceInfo.iosInfo;
      // Two keys are gone from v2 here, for two different reasons (#91):
      //
      // - `device.name` — **removed on privacy grounds.** It is the only key in
      //   the whole static bag that can carry a human's name, because the iOS
      //   default is "Marvin's iPhone".
      // - `device.identifier_for_vendor` — **removed as redundant, not as a
      //   privacy concession.** `device.id` sits beside it, is minted by this
      //   SDK, and survives a reinstall; the vendor id is reset when the last
      //   app from the vendor is deleted. The key we keep is strictly more
      //   stable than the one we drop, so nothing is lost.
      //
      // Carrier is **never built**: no consumer asked for it, and on iOS it has
      // been permanently unreachable since `CTCarrier` was deprecated to a
      // constant — an absent key beats a key that is always wrong.
      attributes.addAll({
        'device.model': iosInfo.model,
        'device.system_name': iosInfo.systemName,
        'device.system_version': iosInfo.systemVersion,
        'device.localized_model': iosInfo.localizedModel,
      });
    } catch (e) {
      attributes['device.ios_error'] = e.toString();
    }
  }
}

/// The process-lifetime id used when neither generation nor storage works.
String? _inMemoryDeviceId;

/// Forget the in-memory fallback id. Tests only — it is process-wide.
@visibleForTesting
void resetInMemoryDeviceId() => _inMemoryDeviceId = null;
