// lib/src/crash/error_category.dart

import 'dart:async' show TimeoutException;
import 'dart:io' show FileSystemException, HttpException, SocketException;

/// The non-fatal error taxonomy (#90, §11), carried on `app.crash` as the new
/// dotted key `error.category`.
///
/// **It is deliberately not `cause`.** `cause` is shipped in both SDKs and means
/// two different things — free text in the sibling, a fixed enum
/// (`Error`/`NativeCrash`/`ANR`/`Hang`) here — so the no-renames rule keeps the
/// taxonomy out of it, on its own dotted key beside the already-dotted
/// `crash.source` / `crash.breadcrumbs`.
enum ErrorCategory {
  network,
  timeout,

  /// Declared-only: no platform type means "the user is not who they claimed".
  auth,
  parse,
  storage,

  /// Declared-only: a business rule violation is an application concept, and
  /// every stdlib type that could carry one means something else too.
  business,

  /// What an uncaught error nobody classified reports. Honest by design — an
  /// inferred `unknown` is a category, not a missing key.
  unknown;

  /// The wire value. The test pins all seven strings, which is what stops a
  /// rename of the symbol from silently renaming a shipped attribute value.
  String get wire => name;
}

/// Where `error.category` came from — the #88/#89 honesty pattern: a consumer
/// reading a dashboard must be able to tell a category the SDK guessed from one
/// the developer asserted.
const String kCategoryInferred = 'inferred';
const String kCategoryDeclared = 'declared';

/// `crash.source` for the SDK's own capture-hook self-diagnostics. Without it
/// an SDK-internal failure is indistinguishable from a host-app error and
/// inflates the host's error rate; with it, the Collector also keeps it off
/// `session.error_count` / `session.crash_count`.
const String kSdkCrashSource = 'sdk';

/// Map [error] to a category by **exact platform type only — never message
/// matching**. A message is a string a library author may reword in a patch
/// release; a type is a compile-time fact.
///
/// `auth` and `business` are absent on purpose: no `dart:core` / `dart:io` type
/// means either, so they are declared-only. Everything unlisted is [unknown] —
/// inference that guesses would be worse than inference that admits.
ErrorCategory inferErrorCategory(Object error) => switch (error) {
  TimeoutException() => ErrorCategory.timeout,
  // Ahead of the two IOException siblings below: a FileSystemException is
  // not a SocketException, but ordering is the cheap guard against a future
  // reader adding a wider type above a narrower one.
  FileSystemException() => ErrorCategory.storage,
  SocketException() => ErrorCategory.network,
  HttpException() => ErrorCategory.network,
  FormatException() => ErrorCategory.parse,
  _ => ErrorCategory.unknown,
};
