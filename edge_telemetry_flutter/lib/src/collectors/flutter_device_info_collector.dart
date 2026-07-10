// lib/src/collectors/flutter_device_info_collector.dart

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/interfaces/device_info_collector.dart';
import '../managers/device_id_manager.dart';

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

      // Collect platform information
      attributes['device.platform'] = Platform.operatingSystem;
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
      attributes.addAll({
        'device.model': iosInfo.model,
        'device.name': iosInfo.name,
        'device.system_name': iosInfo.systemName,
        'device.system_version': iosInfo.systemVersion,
        'device.localized_model': iosInfo.localizedModel,
        'device.identifier_for_vendor':
            iosInfo.identifierForVendor ?? 'unknown',
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
