// lib/src/widgets/edge_navigation_observer.dart

import 'package:flutter/material.dart';

import '../capture/http_url.dart' show templatePath;
import '../core/wire_canon.dart' show utc;

/// Navigation observer that automatically tracks screen changes
///
/// Integrates with Flutter's Navigator to provide automatic
/// screen tracking and navigation analytics
class EdgeNavigationObserver extends NavigatorObserver {
  String? _currentRoute;

  // One record per open screen: when it started, and whether it was ever
  // painted. The screen being left is named by `navigation.from_screen`, so
  // its dwell needs no route context of its own.
  final Map<String, _ScreenVisit> _screens = {};

  final Function(String, {Map<String, String>? attributes})? _onEvent;

  EdgeNavigationObserver({
    Function(String, {Map<String, String>? attributes})? onEvent,
  }) : _onEvent = onEvent;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _handleRouteChange(route, previousRoute, 'push');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) {
      _handleRouteChange(newRoute, oldRoute, 'replace');
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) {
      _handleRouteChange(previousRoute, route, 'pop');
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    // State only, no event. A route plucked out of the middle of the stack is
    // not a navigation — it was not the visible screen, and the user did not
    // leave it.
    _screens.remove(_extractRouteName(route));
  }

  /// Handle navigation route changes
  void _handleRouteChange(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
    String method,
  ) {
    final routeName = _extractRouteName(route);
    final previousRouteName =
        previousRoute != null
            ? _extractRouteName(previousRoute)
            : _currentRoute;

    // Close out the previous screen with its own `screen.duration`.
    if (previousRouteName != null) _endScreen(previousRouteName, method);

    // Start timing the new screen.
    _startScreen(routeName);

    // The first screen has nothing to come from: its method is `initial`.
    _trackNavigationEvent(
      routeName,
      previousRouteName,
      previousRouteName == null ? 'initial' : method,
      route,
    );

    _currentRoute = routeName;
  }

  /// Extract route name from Route object.
  ///
  /// The unnamed fallback is the route's **type**, and deliberately carries no
  /// `hashCode`: an identity-hashed name minted a fresh value on every visit,
  /// so every screen-keyed dashboard carried cardinality equal to total
  /// navigations across all users. Visit identity is what `screen.id` is for;
  /// this is the grouping key, and a grouping key that never repeats groups
  /// nothing.
  ///
  /// A path-shaped name (`/orders/123`) is templated with the HTTP path rule
  /// (`/orders/{id}`): `screen.name` is a route template, never a concrete
  /// URL (catalogue `attributes.yaml`).
  String _extractRouteName(Route<dynamic> route) {
    final name = route.settings.name;
    if (name == null || name.isEmpty) return 'unnamed_${route.runtimeType}';
    return name.startsWith('/') ? templatePath(name) : name;
  }

  /// Begin timing a screen.
  void _startScreen(String routeName) {
    final visit = _ScreenVisit(DateTime.now());
    _screens[routeName] = visit;
    // Was this screen ever actually on screen? A route pushed and superseded
    // within the same frame never painted, and dwell for a screen nobody saw
    // is a row that says a user spent 0 ms somewhere they never were.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => visit.wasVisible = true,
    );
    // Books a seat on the next frame; it does not schedule one. See the same
    // pair in `ScreenLoadHook.enter`.
    WidgetsBinding.instance.scheduleFrame();
  }

  /// The two sanctioned route attrs (glossary §3): the runtime `Route` type and
  /// a boolean args-present flag — never the argument values (PII).
  Map<String, String> _routeContext(Route<dynamic> route) => {
    'navigation.route_type': route.runtimeType.toString(),
    'navigation.has_arguments': (route.settings.arguments != null).toString(),
  };

  /// End a screen: one `screen.duration` for the visit.
  ///
  /// Nothing when the screen was never visible, which is the whole of the
  /// never-painted rule: no event rather than a zero, because a zero is a
  /// measurement.
  void _endScreen(String routeName, String exitMethod) {
    final visit = _screens.remove(routeName);
    if (visit == null || !visit.wasVisible) return;

    _onEvent?.call(
      'screen.duration',
      attributes: {
        'screen.name': routeName,
        'screen.duration_ms':
            DateTime.now().difference(visit.start).inMilliseconds.toString(),
        'screen.exit_method': exitMethod,
        // The visit's entry, which is the row's time (catalogue #31).
        'span.start_time': utc(visit.start),
      },
    );
  }

  /// Track navigation event
  void _trackNavigationEvent(
    String routeName,
    String? previousRouteName,
    String method,
    Route<dynamic> route,
  ) {
    _onEvent?.call(
      'navigation',
      attributes: {
        'navigation.to_screen': routeName,
        if (previousRouteName != null)
          'navigation.from_screen': previousRouteName,
        'navigation.method': method,
        // navigation.route_type + boolean navigation.has_arguments — never
        // the argument values.
        ..._routeContext(route),
      },
    );
  }

  /// Get current route name
  String? get currentRoute => _currentRoute;

  /// Clean up all resources
  void dispose() {
    _screens.clear();
  }
}

/// One open screen's timing anchor.
class _ScreenVisit {
  _ScreenVisit(this.start);

  final DateTime start;

  /// Set by the first post-frame callback after the push — see [_startScreen].
  bool wasVisible = false;
}
