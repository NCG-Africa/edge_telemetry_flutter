// lib/src/crash/crash_reporting.dart

import '../core/edge_event.dart';
import 'error_category.dart';

/// The facade's crash seam: maps a Dart error + the catching handler into one
/// `app.crash` [EdgeEvent], then hands it to the [Collector], which picks the
/// rail from the item's own fatality — immediate for a fatal, batched for a
/// non-fatal.
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

  /// Build the batched non-fatal `app.crash` event for [error]. [source] records
  /// the catching handler; omit it for a host `trackError` with no specific
  /// origin. [category] is the consumer's declaration — left null, the taxonomy
  /// is inferred from the error's exact type.
  EdgeEvent buildCrashEvent(
    Object error, {
    StackTrace? stackTrace,
    String? source,
    Map<String, String>? attributes,
    ErrorCategory? category,
  }) => EdgeEvent.error(
    error,
    stackTrace: stackTrace,
    source: source,
    attributes: attributes,
    category: category,
  );

  /// Build the immediate (fatal) `app.crash` event for one native-drained crash
  /// [payload] (#29). The native side already shaped the unprefixed keys and set
  /// the `NativeCrash`/`ANR`/`Hang` cause + `is_fatal:true` + capture tier — we
  /// carry it verbatim; the Collector folds in identity context downstream.
  EdgeEvent buildNativeCrashEvent(Map<String, String> payload) =>
      EdgeEvent.nativeCrash(payload);
}
