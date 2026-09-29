// lib/src/capture/nav_capture_hook.dart

import '../core/edge_event.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/session_manager.dart';
import '../managers/trace_manager.dart';
import '../widgets/edge_navigation_observer.dart';
import 'capture_hook.dart';
import 'screen_load_hook.dart';

/// The one consumer-placed hook: the [EdgeNavigationObserver] goes into
/// `MaterialApp.navigatorObservers`, but its sink (the Collector) is injected
/// here. Records visited screens + navigation breadcrumbs, then emits the canon
/// `navigation` event direct (which does not bump session counters).
///
/// The departing screen's dwell rides that same event — `screen.duration` is
/// deprecated in place (removal in v4.0.0) — so a navigation is one item, not
/// two.
class NavCaptureHook implements CaptureHook {
  final SessionManager session;
  final BreadcrumbManager breadcrumbs;

  /// Mints a `navigation` root **only when no root is live**, which makes the
  /// rule disjoint by construction from "a screen change never clears the open
  /// action": a tap that pushes a route keeps its own root, and a navigation
  /// nobody tapped — a deep link, a push notification opening a screen — stops
  /// being unattributed. Null in state-only tests.
  final TraceManager? trace;

  /// Per-screen load timing (#88). Driven from here because the route push is
  /// already observed once; null when `Capture.screenLoad` is off.
  final ScreenLoadHook? screenLoad;

  EdgeNavigationObserver? _observer;

  NavCaptureHook(
      {required this.session,
      required this.breadcrumbs,
      this.trace,
      this.screenLoad});

  /// The observer to hand to `MaterialApp` (null until [start] is called).
  EdgeNavigationObserver? get observer => _observer;

  @override
  DisposeHandle start(EventSink sink) {
    final observer = EdgeNavigationObserver(
      onEvent: (eventName, {attributes}) {
        if (eventName == 'navigation' &&
            attributes != null &&
            attributes.containsKey('navigation.to')) {
          final to = attributes['navigation.to']!;
          session.recordScreen(to);
          if (trace != null && trace!.current().isEmpty) {
            trace!.mint(TraceRootType.navigation);
          }
          breadcrumbs.addNavigation(
            to,
            data: {
              'from': attributes['navigation.from'] ?? 'unknown',
              'method': attributes['navigation.method'] ?? 'unknown',
            },
          );
          // After `recordScreen` (which mints this visit's `screen.id`) and
          // after the root mint, so the load's frozen child hangs off the
          // navigation root rather than off nothing.
          screenLoad?.enter(to, routeContext: {
            if (attributes['route.type'] != null)
              'route.type': attributes['route.type']!,
            if (attributes['route.has_arguments'] != null)
              'route.has_arguments': attributes['route.has_arguments']!,
          });
        }
        sink.add(
            EdgeEvent.event(eventName, attributes: attributes ?? const {}));
      },
    );
    _observer = observer;
    return observer.dispose;
  }
}
