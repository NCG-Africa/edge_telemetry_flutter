import 'dart:io';

import 'package:edge_telemetry_flutter/src/core/sdk_version.dart';
import 'package:flutter_test/flutter_test.dart';

/// `sdk.version` is a compile-time constant because Dart cannot read its own
/// package's version at runtime — `package_info_plus` reports the **host app's**
/// version, not ours. A constant can drift from the manifest silently, and a
/// version field that lies is worse than no version field: it makes a fixed
/// defect look live. This is the assertion that stops the drift, and it is why
/// a release bumps two files.
void main() {
  test('kSdkVersion matches the pubspec manifest', () {
    final manifest = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(manifest)?.group(1);

    expect(declared, isNotNull, reason: 'pubspec.yaml has no version: line');
    expect(
      kSdkVersion,
      declared,
      reason:
          'Bump lib/src/core/sdk_version.dart with pubspec.yaml — '
          'sdk.version ships on every item and a stale one misattributes rows '
          'to the wrong SDK build.',
    );
  });
}
