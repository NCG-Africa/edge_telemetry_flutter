// lib/src/managers/context_manager.dart

import 'dart:ui';

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

  /// When true, the accessibility-sensitive device keys
  /// (`device.text_scale_factor`, `device.reduce_motion`) are captured. Off by
  /// default — pending privacy sign-off (glossary §6). `device.platform_brightness`
  /// is benign and always captured, regardless of this flag.
  final bool captureAccessibilityContext;

  ContextManager({
    required this.sessionManager,
    Map<String, String>? global,
    this.networkType = 'unknown',
    this.captureAccessibilityContext = false,
  }) : _global = {...?global};

  /// Set a single global key (e.g. `user.id`, `session.sampled`).
  void setGlobalAttribute(String key, String value) => _global[key] = value;

  /// The enriched attribute set right now: globals, then live session attrs,
  /// then `network.type`. Order matches v1.5.2 `_getEnrichedAttributes`.
  ///
  /// The geo/tenant strip (`location`/`tenant_id`/`geo`) lives in `Collector`,
  /// downstream of where event attributes merge in — see `Collector.add`.
  Map<String, String> snapshot() => {
        ..._global,
        ...sessionManager.getSessionAttributes(),
        'network.type': networkType,
        ..._deviceContext(),
      };

  /// Live rendering/accessibility context read fresh each snapshot (all can
  /// change at runtime), from the passive `PlatformDispatcher` singleton
  /// (glossary §6). `platform_brightness` is benign + always on; the two
  /// accessibility keys are gated behind [captureAccessibilityContext].
  Map<String, String> _deviceContext() {
    final dispatcher = PlatformDispatcher.instance;
    final ctx = <String, String>{
      'device.platform_brightness':
          dispatcher.platformBrightness == Brightness.dark ? 'dark' : 'light',
    };
    if (captureAccessibilityContext) {
      ctx['device.text_scale_factor'] = dispatcher.textScaleFactor.toString();
      ctx['device.reduce_motion'] =
          dispatcher.accessibilityFeatures.disableAnimations.toString();
    }
    return ctx;
  }
}
