// lib/src/core/interfaces/device_info_collector.dart

/// Interface for collecting device and app information
///
/// Implementations should gather platform-specific details like:
/// - Device model, manufacturer, OS version
/// - App name, version, build number
/// - Platform capabilities and characteristics
abstract class DeviceInfoCollector {
  /// Collect device and app information
  ///
  /// Returns a map of key-value pairs with device/app attributes
  /// that will be added to all telemetry spans
  Future<Map<String, String>> collectDeviceInfo();
}
