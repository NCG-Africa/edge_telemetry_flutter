// lib/src/widgets/edge_navigation_observer.dart

import 'package:flutter/material.dart';

/// Navigation observer that automatically tracks screen changes
///
/// Integrates with Flutter's Navigator to provide automatic
/// screen tracking and navigation analytics
class EdgeNavigationObserver extends NavigatorObserver {
  String? _currentRoute;

  // One record per open screen: its start time + the route context, so
  // `screen.duration` can carry the same `route.type` / `route.has_arguments`
  // the `navigation` event did (glossary §3).
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
    _cleanupRoute(route);
  }

  /// Handle navigation route changes
  void _handleRouteChange(
      Route<dynamic> route, Route<dynamic>? previousRoute, String method) {
    final routeName = _extractRouteName(route);
    final previousRouteName = previousRoute != null
        ? _extractRouteName(previousRoute)
        : _currentRoute;

    // Close out the previous screen (emit its duration metric)
    if (previousRouteName != null) {
      _endScreen(previousRouteName, method);
    }

    // Start timing the new screen (recording its route context)
    _startScreen(routeName, route);

    // Track navigation event
    _trackNavigationEvent(routeName, previousRouteName, method, route);

    _currentRoute = routeName;
  }

  /// Extract route name from Route object
  String _extractRouteName(Route<dynamic> route) {
    // Try to get named route first
    if (route.settings.name != null && route.settings.name!.isNotEmpty) {
      return route.settings.name!;
    }

    // Fallback to route type and hash
    final routeType = route.runtimeType.toString();
    final routeHash = route.hashCode.toString();
    return 'screen_${routeType}_$routeHash';
  }

  /// Begin timing a screen (and record its route context for screen.duration)
  void _startScreen(String routeName, Route<dynamic> route) {
    _screens[routeName] = _ScreenVisit(DateTime.now(), _routeContext(route));
  }

  /// The two sanctioned route attrs (glossary §3): the runtime `Route` type and
  /// a boolean args-present flag — never the argument values (PII). Shared by
  /// the `navigation` event and `screen.duration`.
  Map<String, String> _routeContext(Route<dynamic> route) => {
        'route.type': route.runtimeType.toString(),
        'route.has_arguments': (route.settings.arguments != null).toString(),
      };

  /// End a screen and track its duration metric
  void _endScreen(String routeName, String exitMethod) {
    final visit = _screens.remove(routeName);
    if (visit == null) return;

    final duration = DateTime.now().difference(visit.start);
    // Canon: screen dwell is the `screen.duration` event (metric→event, §2).
    _onEvent?.call('screen.duration', attributes: {
      'screen.name': routeName,
      'screen.duration_ms': duration.inMilliseconds.toString(),
      'screen.exit_method': exitMethod,
      ...visit.routeContext,
    });
  }

  /// Track navigation event
  void _trackNavigationEvent(String routeName, String? previousRouteName,
      String method, Route<dynamic> route) {
    final navigationAttributes = <String, String>{
      'navigation.to': routeName,
      'navigation.method': method,
      'navigation.type': 'route_change',
      'navigation.timestamp': DateTime.now().toIso8601String(),
      // route.type + boolean route.has_arguments — never the argument values.
      ..._routeContext(route),
    };

    if (previousRouteName != null) {
      navigationAttributes['navigation.from'] = previousRouteName;
    }

    _onEvent?.call('navigation', attributes: navigationAttributes);
  }

  /// Clean up any remaining timing for a route
  void _cleanupRoute(Route<dynamic> route) {
    final routeName = _extractRouteName(route);
    _endScreen(routeName, 'removed');
  }

  /// Get current route name
  String? get currentRoute => _currentRoute;

  /// Clean up all resources
  void dispose() {
    _screens.clear();
  }
}

/// One open screen's timing anchor + its (PII-safe) route context.
class _ScreenVisit {
  final DateTime start;
  final Map<String, String> routeContext;
  const _ScreenVisit(this.start, this.routeContext);
}
