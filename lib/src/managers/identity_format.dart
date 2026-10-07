// lib/src/managers/identity_format.dart
//
// The family identity contract (ticket #20): device/session/user IDs share a
// canon shape — a `kind_` prefix, epoch-ms timestamp, 16-hex random part, and
// (device/session only) a platform suffix.

import 'dart:io';
import 'dart:math';

const _hex = '0123456789abcdef';
final _secureRandom = Random.secure();

/// [chars] lowercase hex characters from the **one process-lifetime**
/// [Random.secure] above — never a fresh handle per call, which would take a
/// fresh entropy draw on a hot path.
///
/// Width is structural rather than formatted: one nibble is emitted per
/// character straight off the table, so there is no number to zero-pad and no
/// way to produce a short id. That matters because a trace field is not
/// forgiving — `edge_db`'s CHECK demands lowercase **non-zero** hex of an exact
/// width, and the Go processor truncates without validating, so a short or
/// all-zero id dead-letters the *whole event*, not just its trace. Hence the
/// explicit all-zero guard: astronomically unlikely, unrecoverable if hit.
String secureHex(int chars) {
  while (true) {
    final id = String.fromCharCodes(
      Iterable.generate(
        chars,
        (_) => _hex.codeUnitAt(_secureRandom.nextInt(16)),
      ),
    );
    if (id.codeUnits.any((c) => c != 0x30)) return id;
  }
}

/// 16 lowercase hex chars = 64 bits of entropy. The identity random part, the
/// W3C span id and `screen.id` are all this width.
String secureHex16() => secureHex(16);

/// 32 lowercase hex chars = the W3C trace id width.
String secureHex32() => secureHex(32);

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
