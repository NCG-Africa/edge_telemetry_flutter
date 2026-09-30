// lib/src/widgets/edge_navigation_observer.dart

import 'package:flutter/material.dart';

/// Navigation observer that automatically tracks screen changes
///
/// Integrates with Flutter's Navigator to provide automatic
/// screen tracking and navigation analytics
class EdgeNavigationObserver extends NavigatorObserver {
  String? _currentRoute;

  // One record per open screen: when it started, and whether it was ever
  // painted. The screen being left is named by `navigation.from`, so its
  // dwell needs no route context of its own.
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
    // State only, no event. Dwell now rides the `navigation` event, and a
    // route plucked out of the middle of the stack is not a navigation — it
    // was not the visible screen, and the user did not leave it.
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

    // Close out the previous screen — its dwell folds onto the one
    // `navigation` event below rather than emitting a second item.
    final dwell =
        previousRouteName == null
            ? const <String, String>{}
            : _endScreen(previousRouteName, method);

    // Start timing the new screen.
    _startScreen(routeName);

    // Track navigation event
    _trackNavigationEvent(routeName, previousRouteName, method, route, dwell);

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
  String _extractRouteName(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    return 'unnamed_${route.runtimeType}';
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
    'route.type': route.runtimeType.toString(),
    'route.has_arguments': (route.settings.arguments != null).toString(),
  };

  /// End a screen and return the dwell attributes for the `navigation` event.
  ///
  /// Empty when the screen was never visible, which is the whole of the
  /// never-painted rule: no keys rather than a zero, because a zero is a
  /// measurement.
  Map<String, String> _endScreen(String routeName, String exitMethod) {
    final visit = _screens.remove(routeName);
    if (visit == null || !visit.wasVisible) return const {};

    final duration = DateTime.now().difference(visit.start);
    // `previous`-prefixed on purpose: `screen.id` on this event is the screen
    // being entered, so an unprefixed `screen.duration_ms` beside it would
    // read as that screen's. The canon `screen.duration` event keeps its old
    // spelling and is deprecated in place (removal in v4.0.0).
    return {
      'screen.previous_duration_ms': duration.inMilliseconds.toString(),
      'screen.previous_exit_method': exitMethod,
    };
  }

  /// Track navigation event
  void _trackNavigationEvent(
    String routeName,
    String? previousRouteName,
    String method,
    Route<dynamic> route,
    Map<String, String> dwell,
  ) {
    final navigationAttributes = <String, String>{
      'navigation.to': routeName,
      'navigation.method': method,
      'navigation.type': 'route_change',
      'navigation.timestamp': DateTime.now().toIso8601String(),
      // route.type + boolean route.has_arguments — never the argument values.
      ..._routeContext(route),
      ...dwell,
    };

    if (previousRouteName != null) {
      navigationAttributes['navigation.from'] = previousRouteName;
    }

    _onEvent?.call('navigation', attributes: navigationAttributes);
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
