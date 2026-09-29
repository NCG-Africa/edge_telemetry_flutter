// lib/src/capture/lifecycle_capture_hook.dart

import 'package:flutter/widgets.dart';

import '../core/capture_gate.dart';
import '../core/config/collection_tier.dart';
import '../core/edge_event.dart';
import '../managers/breadcrumb_manager.dart';
import '../managers/session_manager.dart';
import '../managers/trace_manager.dart';
import 'capture_hook.dart';

/// Bridges `AppLifecycleState` to the session model (spec #15 §2.2) and emits
/// the canon `app_lifecycle` event.
///
/// - `paused`: emit the lifecycle event, **flush** the Pipeline (nothing lost to
///   a subsequent kill), then [SessionManager.handlePause] (mark, don't
///   finalize) and [TraceManager.clear].
/// - `resumed`: [SessionManager.handleResume] first (rotate if idle past the
///   window) so the lifecycle event lands on the correct session.
class LifecycleCaptureHook with WidgetsBindingObserver implements CaptureHook {
  final SessionManager session;

  /// Cleared on `paused` beside the session mark. Load-bearing rather than
  /// belt-and-braces: Dart has no elapsed-realtime analogue and `Stopwatch`
  /// across device suspend is unverified, so the root's wall-clock TTL cannot
  /// be trusted to age out a root the user backgrounded. This hook is always
  /// on — it drives the session model, not an optional monitor — which is what
  /// makes the clear hold without a new dispose handle. Null in state-only
  /// tests.
  final TraceManager? trace;

  /// Flushes the Pipeline buffer (wired to `pipeline.flush`).
  final void Function() flush;

  /// Crash-context ring: each lifecycle transition drops a breadcrumb.
  final BreadcrumbManager? breadcrumbs;

  /// Tier gate for the `app_lifecycle` **event** only — the session bridge
  /// below is unconditional. Null = emit everything (state-only tests).
  final CaptureGate? gate;

  EventSink? _sink;

  LifecycleCaptureHook(
      {required this.session,
      required this.flush,
      this.trace,
      this.breadcrumbs,
      this.gate});

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
      trace?.clear();
    } else if (state == AppLifecycleState.resumed) {
      session.handleResume();
      _emit(state);
    } else {
      _emit(state);
    }
  }

  /// `paused` / `resumed` are `Capture.lifecycle`; the three states nothing
  /// reads — `inactive`, `hidden`, `detached`, all of them synthesized by the
  /// framework on every backgrounding round-trip — are
  /// `Capture.lifecycleTransitions` and opt-in.
  ///
  /// The gate check goes **before** the attribute map, never after: a gated-off
  /// state costs one branch, not a built-and-discarded item.
  void _emit(AppLifecycleState state) {
    final capture =
        state == AppLifecycleState.paused || state == AppLifecycleState.resumed
            ? Capture.lifecycle
            : Capture.lifecycleTransitions;
    if (gate != null && !gate!.allows(capture)) return;

    breadcrumbs?.addSystemEvent('lifecycle: ${state.name}',
        data: {'lifecycle.state': state.name});
    _sink?.add(EdgeEvent.event('app_lifecycle', attributes: {
      'lifecycle.state': state.name,
    }));
  }
}
