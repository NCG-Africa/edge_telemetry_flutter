// lib/src/managers/breadcrumb_manager.dart

import 'dart:collection';

import '../core/models/breadcrumb.dart';

/// Manages breadcrumb collection for crash context
class BreadcrumbManager {
  // Crash-scoped ring cap (spec #15 §5.5), 20 → 50 in v3 (#90, conforming the
  // sibling). Twenty was measured to be too small once actions are captured:
  // ~20 taps evicts every navigation and network crumb from crash triage, which
  // is the half a stack trace does not already tell you. What a given crash
  // *ships* is a separate decision — see [getBreadcrumbs].
  static const int _maxBreadcrumbs = 50;

  /// How many crumbs a **non-fatal** error ships. A fatal ships all 50 because
  /// it is the one item that has to explain itself; 50 non-fatals × 50 crumbs
  /// would be ~110 KB against a 120 KB session ceiling, so a non-fatal ships the
  /// newest handful and no more.
  static const int nonFatalBreadcrumbs = 10;
  final Queue<Breadcrumb> _breadcrumbs = Queue<Breadcrumb>();
  final bool _debugMode;

  BreadcrumbManager({bool debugMode = false}) : _debugMode = debugMode;

  /// Add a breadcrumb
  void addBreadcrumb(
    String message, {
    String category = BreadcrumbCategory.custom,
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
      print(
        '🍞 Breadcrumb: [$category] $message (${_breadcrumbs.length}/$_maxBreadcrumbs)',
      );
    }
  }

  /// Add navigation breadcrumb
  void addNavigation(String route, {Map<String, String>? data}) {
    addBreadcrumb(
      'Navigated to $route',
      category: BreadcrumbCategory.navigation,
      level: BreadcrumbLevel.info,
      data: {'route': route, ...?data},
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
  void addSystemEvent(
    String event, {
    BreadcrumbLevel level = BreadcrumbLevel.info,
    Map<String, String>? data,
  }) {
    addBreadcrumb(
      'System: $event',
      category: BreadcrumbCategory.system,
      level: level,
      data: data,
    );
  }

  /// Add network event breadcrumb
  void addNetworkEvent(
    String event, {
    BreadcrumbLevel level = BreadcrumbLevel.info,
    Map<String, String>? data,
  }) {
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
  void addCustom(
    String message, {
    BreadcrumbLevel level = BreadcrumbLevel.info,
    Map<String, String>? data,
  }) {
    addBreadcrumb(
      message,
      category: BreadcrumbCategory.custom,
      level: level,
      data: data,
    );
  }

  /// Get all breadcrumbs as a list (most recent first), newest [limit] only
  /// when given.
  List<Breadcrumb> getBreadcrumbs({int? limit}) {
    final newestFirst = _breadcrumbs.toList().reversed;
    return (limit == null ? newestFirst : newestFirst.take(limit)).toList();
  }

  /// Get breadcrumbs as JSON for crash reports. [limit] slices the newest N —
  /// [nonFatalBreadcrumbs] for a non-fatal, unset for a fatal.
  List<Map<String, dynamic>> getBreadcrumbsAsJson({int? limit}) {
    return getBreadcrumbs(limit: limit).map((b) => b.toJson()).toList();
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
