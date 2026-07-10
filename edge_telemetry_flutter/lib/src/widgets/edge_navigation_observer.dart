// lib/src/widgets/edge_navigation_observer.dart

import 'package:flutter/material.dart';
import 'package:opentelemetry/api.dart';

/// Navigation observer that automatically tracks screen changes
///
/// Integrates with Flutter's Navigator to provide automatic
/// screen tracking and navigation analytics
class EdgeNavigationObserver extends NavigatorObserver {
  String? _currentRoute;
  final Map<String, Span> _activeScreenSpans = {};
  final Map<String, DateTime> _screenStartTimes = {};

  final Function(String, {Map<String, String>? attributes})? _onEvent;
  final Function(String, double, {Map<String, String>? attributes})? _onMetric;
  final Function(String, {Map<String, String>? attributes})? _onSpanStart;
  final Function(Span)? _onSpanEnd;

  EdgeNavigationObserver({
    Function(String, {Map<String, String>? attributes})? onEvent,
    Function(String, double, {Map<String, String>? attributes})? onMetric,
    Function(String, {Map<String, String>? attributes})? onSpanStart,
    Function(Span)? onSpanEnd,
  })  : _onEvent = onEvent,
        _onMetric = onMetric,
        _onSpanStart = onSpanStart,
        _onSpanEnd = onSpanEnd;

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

    // End previous screen span
    if (previousRouteName != null) {
      _endScreenSpan(previousRouteName, method);
    }

    // Start new screen span
    _startScreenSpan(routeName, method, previousRouteName);

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

  /// Start a new screen span
  void _startScreenSpan(
      String routeName, String method, String? previousRouteName) {
    final startTime = DateTime.now();

    // Notify about span start (will be handled by the main telemetry class)
    _onSpanStart?.call('screen.$routeName', attributes: {
      'screen.name': routeName,
      'screen.start_time': startTime.toIso8601String(),
      'navigation.method': method,
      if (previousRouteName != null) 'navigation.from': previousRouteName,
      'screen.type': 'auto_tracked',
    });

    _screenStartTimes[routeName] = startTime;
  }

  /// End a screen span and track duration
  void _endScreenSpan(String routeName, String exitMethod) {
    final span = _activeScreenSpans.remove(routeName);
    final startTime = _screenStartTimes.remove(routeName);

    if (span != null && startTime != null) {
      final duration = DateTime.now().difference(startTime);

      // Add duration to span
      span.setAttribute(Attribute.fromString(
        'screen.duration_ms',
        duration.inMilliseconds.toString(),
      ));

      span.setAttribute(Attribute.fromString(
        'screen.exit_method',
        exitMethod,
      ));

      // Track screen duration metric
      _onMetric?.call(
          'performance.screen_duration', duration.inMilliseconds.toDouble(),
          attributes: {
            'screen.name': routeName,
            'navigation.exit_method': exitMethod,
            'metric.unit': 'milliseconds',
          });

      // End the span
      _onSpanEnd?.call(span);
    } else if (startTime != null) {
      // We have start time but no span, still track the metric
      final duration = DateTime.now().difference(startTime);
      _onMetric?.call(
          'performance.screen_duration', duration.inMilliseconds.toDouble(),
          attributes: {
            'screen.name': routeName,
            'navigation.exit_method': exitMethod,
            'metric.unit': 'milliseconds',
          });
    }
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

    _onEvent?.call('navigation.route_change', attributes: navigationAttributes);
  }

  /// Clean up any remaining spans for a route
  void _cleanupRoute(Route<dynamic> route) {
    final routeName = _extractRouteName(route);
    _endScreenSpan(routeName, 'removed');
  }

  /// Register a span for a screen (called by main telemetry class)
  void registerScreenSpan(String routeName, Span span) {
    _activeScreenSpans[routeName] = span;
  }

  /// Get current route name
  String? get currentRoute => _currentRoute;

  /// Get active screen spans (for debugging)
  Map<String, Span> get activeScreenSpans =>
      Map.unmodifiable(_activeScreenSpans);

  /// Clean up all resources
  void dispose() {
    // End all active spans
    for (final entry in _activeScreenSpans.entries) {
      _endScreenSpan(entry.key, 'disposed');
    }
    _activeScreenSpans.clear();
    _screenStartTimes.clear();
  }
}
