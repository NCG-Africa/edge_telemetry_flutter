// lib/src/collectors/flutter_device_info_collector.dart

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/interfaces/device_info_collector.dart';
import '../core/sdk_version.dart';
import '../managers/device_id_manager.dart';
import '../managers/identity_format.dart';

/// Flutter implementation of device information collector
///
/// Collects device, platform, and app information using Flutter plugins
class FlutterDeviceInfoCollector implements DeviceInfoCollector {
  final DeviceIdManager _deviceIdManager = DeviceIdManager();

  @override
  Future<Map<String, String>> collectDeviceInfo() async {
    final attributes = <String, String>{};

    // Step 1: Get persistent device ID first
    try {
      final deviceId = await _deviceIdManager.getDeviceId();
      attributes['device.id'] = deviceId;
      print('✅ Device ID: $deviceId');
    } catch (e) {
      print('⚠️ Device ID generation failed: $e');
      attributes['device.id_error'] = e.toString();
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

      // Collect platform information.
      // device.platform = real OS; sdk.platform = flutter-{os} (ticket #20).
      // platformTag() is the same lowercased token baked into device/session IDs.
      final platform = platformTag();
      attributes['device.platform'] = platform;
      attributes['sdk.platform'] = 'flutter-$platform';
      // Which SDK build produced this row. A compile-time constant because
      // Dart cannot read its own package's version at runtime — see
      // [kSdkVersion] for the manifest assertion that keeps it honest.
      attributes['sdk.version'] = kSdkVersion;
      attributes['device.platform_version'] = Platform.operatingSystemVersion;

      // Collect platform-specific device information
      await _collectPlatformSpecificInfo(attributes);
    } catch (e) {
      // If collection fails, add error info but continue
      attributes['device.info_error'] = e.toString();
    }

    return attributes;
  }

  /// Collect platform-specific device information
  Future<void> _collectPlatformSpecificInfo(
      Map<String, String> attributes) async {
    final deviceInfo = DeviceInfoPlugin();

    if (kIsWeb) {
      await _collectWebInfo(deviceInfo, attributes);
    } else if (Platform.isAndroid) {
      await _collectAndroidInfo(deviceInfo, attributes);
    } else if (Platform.isIOS) {
      await _collectIOSInfo(deviceInfo, attributes);
    }
  }

  /// Collect Android-specific information
  Future<void> _collectAndroidInfo(
      DeviceInfoPlugin deviceInfo, Map<String, String> attributes) async {
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
      DeviceInfoPlugin deviceInfo, Map<String, String> attributes) async {
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

  /// Collect web-specific information
  Future<void> _collectWebInfo(
      DeviceInfoPlugin deviceInfo, Map<String, String> attributes) async {
    try {
      final webInfo = await deviceInfo.webBrowserInfo;
      attributes.addAll({
        'device.browser': webInfo.browserName.toString().split('.').last,
        'device.platform': webInfo.platform ?? 'web',
        'device.user_agent': webInfo.userAgent ?? 'unknown',
        'device.vendor': webInfo.vendor ?? 'unknown',
        'device.language': webInfo.language ?? 'unknown',
      });
    } catch (e) {
      attributes['device.web_error'] = e.toString();
    }
  }
}
