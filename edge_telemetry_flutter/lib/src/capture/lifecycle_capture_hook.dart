// lib/src/capture/lifecycle_capture_hook.dart

import 'package:flutter/widgets.dart';

import '../core/edge_event.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/session_manager.dart';
import 'capture_hook.dart';

/// Bridges `AppLifecycleState` to the session model (spec #15 §2.2) and emits
/// the canon `app_lifecycle` event.
///
/// - `paused`: emit the lifecycle event, **flush** the Pipeline (nothing lost to
///   a subsequent kill), then [SessionManager.handlePause] (mark, don't
///   finalize).
/// - `resumed`: [SessionManager.handleResume] first (rotate if idle past the
///   window) so the lifecycle event lands on the correct session.
class LifecycleCaptureHook with WidgetsBindingObserver implements CaptureHook {
  final SessionManager session;

  /// Flushes the Pipeline buffer (wired to `pipeline.flush`).
  final void Function() flush;

  /// Crash-context ring: each lifecycle transition drops a breadcrumb.
  final BreadcrumbManager? breadcrumbs;

  EventSink? _sink;

  LifecycleCaptureHook(
      {required this.session, required this.flush, this.breadcrumbs});

  @override
  DisposeHandle start(EventSink sink) {
    _sink = sink;
    WidgetsBinding.instance.addObserver(this);
    return () => WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _emit(state);
      flush();
      session.handlePause();
    } else if (state == AppLifecycleState.resumed) {
      session.handleResume();
      _emit(state);
    } else {
      _emit(state);
    }
  }

  void _emit(AppLifecycleState state) {
    breadcrumbs?.addSystemEvent('lifecycle: ${state.name}',
        data: {'lifecycle.state': state.name});
    _sink?.add(EdgeEvent.event('app_lifecycle', attributes: {
      'lifecycle.state': state.name,
    }));
  }
}
