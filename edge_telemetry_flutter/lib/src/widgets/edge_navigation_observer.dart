// lib/src/widgets/edge_navigation_observer.dart

import 'package:flutter/material.dart';

/// Navigation observer that automatically tracks screen changes
///
/// Integrates with Flutter's Navigator to provide automatic
/// screen tracking and navigation analytics
class EdgeNavigationObserver extends NavigatorObserver {
  String? _currentRoute;
  final Map<String, DateTime> _screenStartTimes = {};

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

    // Start timing the new screen
    _startScreen(routeName);

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

  /// Begin timing a screen
  void _startScreen(String routeName) {
    _screenStartTimes[routeName] = DateTime.now();
  }

  /// End a screen and track its duration metric
  void _endScreen(String routeName, String exitMethod) {
    final startTime = _screenStartTimes.remove(routeName);
    if (startTime == null) return;

    final duration = DateTime.now().difference(startTime);
    // Canon: screen dwell is the `screen.duration` event (metric→event, §2).
    _onEvent?.call('screen.duration', attributes: {
      'screen.name': routeName,
      'screen.duration_ms': duration.inMilliseconds.toString(),
      'screen.exit_method': exitMethod,
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
      'route.type': route.runtimeType.toString(),
    };

    if (previousRouteName != null) {
      navigationAttributes['navigation.from'] = previousRouteName;
    }

    // Add route arguments if available
    if (route.settings.arguments != null) {
      navigationAttributes['route.has_arguments'] = 'true';
      navigationAttributes['route.arguments_type'] =
          route.settings.arguments.runtimeType.toString();
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
    _screenStartTimes.clear();
  }
}
