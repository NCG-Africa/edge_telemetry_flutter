// lib/src/crash/crash_reporting.dart

import '../core/edge_event.dart';

/// The facade's crash seam: maps a Dart error + the catching handler into one
/// immediate `app.crash` [EdgeEvent], then hands it to the [Collector] (which
/// routes it down the crash rail).
///
/// Every handler — `FlutterError.onError`, `PlatformDispatcher.onError`,
/// `runZonedGuarded`, the isolate error-listener, and host `trackError` —
/// funnels here with its own [source] token (`flutter_error` /
/// `platform_dispatcher` / `zone` / `isolate`), so `cause` stays a clean
/// fatal/non-fatal taxonomy (`Error`, non-fatal) while the triage detail lives
/// in the secondary `crash.source`. Payload keys are unprefixed and the client
/// derives nothing (`crash_hash`/`severity`/`breadcrumbs` are server-computed)
/// — the wire shape is owned by [EdgeEvent.error].
class CrashReporting {
  const CrashReporting();

  /// Build the immediate `app.crash` event for [error]. [source] records the
  /// catching handler; omit it for a host `trackError` with no specific origin.
  EdgeEvent buildCrashEvent(
    Object error, {
    StackTrace? stackTrace,
    String? source,
    Map<String, String>? attributes,
  }) =>
      EdgeEvent.error(error,
          stackTrace: stackTrace, source: source, attributes: attributes);
}
