// lib/src/capture/capture_hook.dart

import '../core/edge_event.dart';

/// Disposes a started [CaptureHook]. Returned from [CaptureHook.start] so a hook
/// can be torn down (restoring globals, cancelling subscriptions) without a
/// leak across hot-restarts.
typedef DisposeHandle = void Function();

/// The seam every capture source emits through. Implemented by the [Collector].
///
/// Named `EventSink` per the target architecture. Kept in this file (which does
/// not import `dart:async`) to avoid clashing with `dart:async`'s `EventSink`.
abstract class EventSink {
  void add(EdgeEvent event);
}

/// A source of telemetry (HTTP, navigation, performance, network) that, once
/// [start]ed with a sink, feeds [EdgeEvent]s into it and returns a dispose
/// handle.
abstract class CaptureHook {
  DisposeHandle start(EventSink sink);
}
