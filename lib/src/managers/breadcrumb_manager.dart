// lib/src/managers/breadcrumb_manager.dart

import 'dart:collection';

import '../core/models/breadcrumb.dart';

/// Manages breadcrumb collection for crash context
class BreadcrumbManager {
  static const int _maxBreadcrumbs = 50;
  final Queue<Breadcrumb> _breadcrumbs = Queue<Breadcrumb>();
  final bool _debugMode;

  BreadcrumbManager({bool debugMode = false}) : _debugMode = debugMode;

  /// Add a breadcrumb
  void addBreadcrumb(
    String message, {
    required String category,
    BreadcrumbLevel level = BreadcrumbLevel.info,
    Map<String, String>? data,
  }) {
    final breadcrumb = Breadcrumb(
      message: message,
      category: category,
      level: level,
      timestamp: DateTime.now(),
      data: data,
    );

    _breadcrumbs.addLast(breadcrumb);

    // Keep only the most recent breadcrumbs
    if (_breadcrumbs.length > _maxBreadcrumbs) {
      _breadcrumbs.removeFirst();
    }

    if (_debugMode) {
      print('🍞 Breadcrumb: [$category] $message (${_breadcrumbs.length}/$_maxBreadcrumbs)');
    }
  }

  /// Add navigation breadcrumb
  void addNavigation(String route, {Map<String, String>? data}) {
    addBreadcrumb(
      'Navigated to $route',
      category: BreadcrumbCategory.navigation,
      level: BreadcrumbLevel.info,
      data: {
        'route': route,
        ...?data,
      },
    );
  }

  /// Add user action breadcrumb
  void addUserAction(String action, {Map<String, String>? data}) {
    addBreadcrumb(
      'User: $action',
      category: BreadcrumbCategory.user,
      level: BreadcrumbLevel.info,
      data: data,
    );
  }

  /// Add system event breadcrumb
  void addSystemEvent(String event, {BreadcrumbLevel level = BreadcrumbLevel.info, Map<String, String>? data}) {
    addBreadcrumb(
      'System: $event',
      category: BreadcrumbCategory.system,
      level: level,
      data: data,
    );
  }

  /// Add network event breadcrumb
  void addNetworkEvent(String event, {BreadcrumbLevel level = BreadcrumbLevel.info, Map<String, String>? data}) {
    addBreadcrumb(
      'Network: $event',
      category: BreadcrumbCategory.network,
      level: level,
      data: data,
    );
  }

  /// Add UI event breadcrumb
  void addUIEvent(String event, {Map<String, String>? data}) {
    addBreadcrumb(
      'UI: $event',
      category: BreadcrumbCategory.ui,
      level: BreadcrumbLevel.info,
      data: data,
    );
  }

  /// Add custom breadcrumb
  void addCustom(String message, {BreadcrumbLevel level = BreadcrumbLevel.info, Map<String, String>? data}) {
    addBreadcrumb(
      message,
      category: BreadcrumbCategory.custom,
      level: level,
      data: data,
    );
  }

  /// Get all breadcrumbs as a list (most recent first)
  List<Breadcrumb> getBreadcrumbs() {
    return _breadcrumbs.toList().reversed.toList();
  }

  /// Get breadcrumbs as JSON for crash reports
  List<Map<String, dynamic>> getBreadcrumbsAsJson() {
    return getBreadcrumbs().map((b) => b.toJson()).toList();
  }

  /// Clear all breadcrumbs
  void clear() {
    _breadcrumbs.clear();
    if (_debugMode) {
      print('🧹 Breadcrumbs cleared');
    }
  }

  /// Get breadcrumb count
  int get count => _breadcrumbs.length;

  /// Get max breadcrumb limit
  int get maxBreadcrumbs => _maxBreadcrumbs;
}
