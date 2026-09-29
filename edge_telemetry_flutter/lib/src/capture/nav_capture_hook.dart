// lib/src/capture/nav_capture_hook.dart

import '../core/edge_event.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/session_manager.dart';
import '../managers/trace_manager.dart';
import '../widgets/edge_navigation_observer.dart';
import 'capture_hook.dart';

/// The one consumer-placed hook: the [EdgeNavigationObserver] goes into
/// `MaterialApp.navigatorObservers`, but its sink (the Collector) is injected
/// here. Records visited screens + navigation breadcrumbs, then emits the same
/// canon `navigation` + `screen.duration` events direct (which do not bump
/// session counters).
class NavCaptureHook implements CaptureHook {
  final SessionManager session;
  final BreadcrumbManager breadcrumbs;

  /// Mints a `navigation` root **only when no root is live**, which makes the
  /// rule disjoint by construction from "a screen change never clears the open
  /// action": a tap that pushes a route keeps its own root, and a navigation
  /// nobody tapped — a deep link, a push notification opening a screen — stops
  /// being unattributed. Null in state-only tests.
  final TraceManager? trace;

  EdgeNavigationObserver? _observer;

  NavCaptureHook(
      {required this.session, required this.breadcrumbs, this.trace});

  /// The observer to hand to `MaterialApp` (null until [start] is called).
  EdgeNavigationObserver? get observer => _observer;

  @override
  DisposeHandle start(EventSink sink) {
    final observer = EdgeNavigationObserver(
      onEvent: (eventName, {attributes}) {
        if (eventName == 'navigation' &&
            attributes != null &&
            attributes.containsKey('navigation.to')) {
          session.recordScreen(attributes['navigation.to']!);
          if (trace != null && trace!.current().isEmpty) {
            trace!.mint(TraceRootType.navigation);
          }
          breadcrumbs.addNavigation(
            attributes['navigation.to']!,
            data: {
              'from': attributes['navigation.from'] ?? 'unknown',
              'method': attributes['navigation.method'] ?? 'unknown',
            },
          );
        }
        sink.add(
            EdgeEvent.event(eventName, attributes: attributes ?? const {}));
      },
    );
    _observer = observer;
    return observer.dispose;
  }
}
