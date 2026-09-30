// lib/src/core/sdk_version.dart

/// This package's own version, as a compile-time constant.
///
/// The gap analysis's most damaging static-context omission: a backend that
/// cannot tell which SDK build produced a row cannot tell a fixed defect from a
/// live one. Dart offers no runtime read of the *package's* own version —
/// `package_info_plus` reports the **host app's**, not ours — so a constant is
/// the only option, and a constant can drift from `pubspec.yaml` silently.
///
/// `test/unit/core/sdk_version_test.dart` asserts the two agree by parsing the
/// manifest, so a release that bumps one and forgets the other fails the suite
/// rather than shipping a lie.
///
/// Framework version is **rejected, not deferred**: Flutter's version is
/// build-time only, and reaching it means code generation in a published
/// package for a field no consumer asked for.
const String kSdkVersion = '3.0.0';
