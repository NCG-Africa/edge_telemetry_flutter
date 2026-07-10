// lib/src/capture/nav_capture_hook.dart

import '../core/edge_event.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/session_manager.dart';
import '../widgets/edge_navigation_observer.dart';
import 'capture_hook.dart';

/// The one consumer-placed hook: the [EdgeNavigationObserver] goes into
/// `MaterialApp.navigatorObservers`, but its sink (the Collector) is injected
/// here. Records visited screens + navigation breadcrumbs, then emits the same
/// `navigation.route_change` / `performance.screen_duration` wire items as
/// v1.5.2 (which sent them direct — they do not bump session counters).
class NavCaptureHook implements CaptureHook {
  final SessionManager session;
  final BreadcrumbManager breadcrumbs;

  EdgeNavigationObserver? _observer;

  NavCaptureHook({required this.session, required this.breadcrumbs});

  /// The observer to hand to `MaterialApp` (null until [start] is called).
  EdgeNavigationObserver? get observer => _observer;

  @override
  DisposeHandle start(EventSink sink) {
    final observer = EdgeNavigationObserver(
      onEvent: (eventName, {attributes}) {
        if (eventName == 'navigation.route_change' &&
            attributes != null &&
            attributes.containsKey('navigation.to')) {
          session.recordScreen(attributes['navigation.to']!);
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
      onMetric: (name, value, {attributes}) {
        sink.add(
            EdgeEvent.metric(name, value, attributes: attributes ?? const {}));
      },
    );
    _observer = observer;
    return observer.dispose;
  }
}
