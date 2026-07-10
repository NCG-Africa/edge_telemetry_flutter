// lib/src/crash/crash_reporting.dart

import '../core/edge_event.dart';
import '../managers/breadcrumb_manager.dart';

/// Builds the crash event: computes the grouping fingerprint and attaches the
/// pre-crash breadcrumb ring, then hands an immediate-priority [EdgeEvent] to the
/// [Collector] (which routes it down the one crash rail).
class CrashReporting {
  final BreadcrumbManager breadcrumbs;

  CrashReporting(this.breadcrumbs);

  /// Fingerprint for grouping similar crashes: `ErrorType_msgHash_stackHash`.
  String fingerprint(Object error, StackTrace? stackTrace) {
    final errorType = error.runtimeType.toString();
    final errorMessage = error.toString();
    final topStackFrame = stackTrace?.toString().split('\n').firstWhere(
              (line) => line.trim().isNotEmpty,
              orElse: () => 'no_stack',
            ) ??
        'no_stack';
    return '${errorType}_${errorMessage.hashCode}_${topStackFrame.hashCode}';
  }

  /// Build the enrichable crash event. Attribute order (breadcrumbs, then
  /// `crash.fingerprint`, `crash.breadcrumb_count`, then caller attrs) is held
  /// byte-identical with v1.5.2's `_getEnrichedAttributes` crash path.
  EdgeEvent buildCrashEvent(
    Object error, {
    StackTrace? stackTrace,
    Map<String, String>? attributes,
  }) {
    final crumbs = breadcrumbs.getBreadcrumbsAsJson();
    final attrs = <String, String>{
      if (crumbs.isNotEmpty) 'breadcrumbs': crumbs.toString(),
      'crash.fingerprint': fingerprint(error, stackTrace),
      'crash.breadcrumb_count': crumbs.length.toString(),
      ...?attributes,
    };
    return EdgeEvent.error(error, stackTrace: stackTrace, attributes: attrs);
  }
}
