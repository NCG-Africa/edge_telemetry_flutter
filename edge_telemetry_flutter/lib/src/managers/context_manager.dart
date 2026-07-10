// lib/src/managers/context_manager.dart

import 'session_manager.dart';

/// Single source of truth for the mutable global context bag: `device.*`,
/// `app.*`, `user.id`, live `session.*`, and `network.type`.
///
/// [snapshot] is the testable replacement for the barrel's untestable
/// `_getEnrichedAttributes` state half — the enriched attribute set at this
/// instant, minus per-event extras (breadcrumbs) which the [Collector] attaches.
class ContextManager {
  final SessionManager sessionManager;
  final Map<String, String> _global;

  /// Current network type; updated by the network capture hook.
  String networkType;

  ContextManager({
    required this.sessionManager,
    Map<String, String>? global,
    this.networkType = 'unknown',
  }) : _global = {...?global};

  /// Set a single global key (e.g. `user.id`, `session.sampled`).
  void setGlobalAttribute(String key, String value) => _global[key] = value;

  /// The enriched attribute set right now: globals, then live session attrs,
  /// then `network.type`. Order matches v1.5.2 `_getEnrichedAttributes`.
  Map<String, String> snapshot() => {
        ..._global,
        ...sessionManager.getSessionAttributes(),
        'network.type': networkType,
      };
}
