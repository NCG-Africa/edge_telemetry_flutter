// lib/src/managers/identity_format.dart
//
// The family identity contract (ticket #20): device/session/user IDs share a
// canon shape — a `kind_` prefix, epoch-ms timestamp, 16-hex random part, and
// (device/session only) a platform suffix.

import 'dart:io';
import 'dart:math';

const _hex = '0123456789abcdef';
final _secureRandom = Random.secure();

/// 16 lowercase hex chars = 64 bits of entropy from [Random.secure].
String secureHex16() => String.fromCharCodes(
      Iterable.generate(16, (_) => _hex.codeUnitAt(_secureRandom.nextInt(16))),
    );

/// The lowercased real-OS token baked into the device/session ID platform leg
/// (`ios`/`android` on device). One source so every leg agrees.
String platformTag() {
  try {
    return Platform.operatingSystem.toLowerCase();
  } catch (_) {
    return 'unknown';
  }
}

/// Accepts BOTH the legacy 8-char alnum width and the new 16-hex width, so
/// IDs minted before this contract keep validating and upgrade in place.
bool isValidRandomPart(String part) =>
    RegExp(r'^[a-z0-9]{8}$').hasMatch(part) ||
    RegExp(r'^[0-9a-f]{16}$').hasMatch(part);
