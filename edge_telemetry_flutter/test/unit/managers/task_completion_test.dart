// test/unit/managers/task_completion_test.dart
//
// Wayfinder #92 — the task-completion model. Asserts the three calls, the
// terminal-only event, the two abandonment triggers that are *not* triggers,
// the start-frozen trace context, and the wire seam that matters most: a
// kill-recovered abandonment arriving with its attribution intact and a
// believable duration.

import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/core/wire_canon.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/trace_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];

  List<Map<String, dynamic>> get items => [
        for (final p in sent)
          ...?(p['events'] as List?)?.cast<Map<String, dynamic>>()
      ];

  Future<bool> call(Map<String, dynamic> payload) async {
    sent.add(payload);
    return true;
  }
}

class _NoopQueue extends OfflineQueue {
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> persist(Map<String, dynamic> p,
          {bool isCrash = false}) async =>
      null;
  @override
  Future<int> drain(
          Future<DrainResult> Function(Map<String, dynamic>) s) async =>
      0;
}

/// The facade's `completeTask` in one line, so the tests read like the API
/// consumers actually call rather than like the manager's two-argument close.
extension on SessionManager {
  void endTaskCompleted(String name) => endTask(name, TaskOutcome.completed);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const idle = Duration(minutes: 30);
  const recordKey = 'edge_telemetry_session_record';

  late List<EdgeEvent> emitted;
  late DateTime clock;
  late int ids;

  SessionManager build() => SessionManager(
        emit: emitted.add,
        newSessionId: () => 'session_${++ids}',
        clock: () => clock,
        idleTimeout: idle,
      );

  List<EdgeEvent> tasks() =>
      emitted.where((e) => e.name == 'task.complete').toList();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    emitted = [];
    clock = DateTime(2026, 1, 1, 9, 0, 0);
    ids = 0;
  });

  group('the three calls', () {
    test('the name is canon, so the allowlist cannot drop it', () {
      expect(kCanonEvents, contains('task.complete'));
    });

    test('a start costs no wire item; the terminal is the one event', () async {
      final sm = build();
      await sm.recoverAndStart();
      emitted.clear();

      sm.startTask('transfer');
      expect(tasks(), isEmpty, reason: 'the start is held, not emitted');

      clock = clock.add(const Duration(minutes: 3));
      sm.endTaskCompleted('transfer');

      final e = tasks().single;
      expect(e.attributes['task.name'], 'transfer');
      expect(e.attributes['task.outcome'], TaskOutcome.completed.name);
      // Time on task rides the *existing* span duration key.
      expect(e.attributes['span.duration_ms'],
          const Duration(minutes: 3).inMilliseconds.toString());
      expect(e.attributes.containsKey('task.duration_ms'), isFalse);
      expect(e.attributes['task.abandon_source'], isNull);
      // Batched, subject to sampling, and owns its own (frozen) trace context.
      expect(e.priority, EventPriority.batched);
      expect(e.bypassSampling, isFalse);
      expect(e.ownsTraceContext, isTrue);
      expect(e.countsToSession, isFalse);
    });

    test('failTask is a distinct outcome, not an abandonment', () async {
      final sm = build();
      await sm.recoverAndStart();
      sm.startTask('transfer');
      sm.endTask('transfer', TaskOutcome.failed);

      expect(
          tasks().single.attributes['task.outcome'], TaskOutcome.failed.name);
      expect(tasks().single.attributes['task.abandon_source'], isNull);
    });

    test('Apdex ships zero events, zero attributes, zero bytes', () async {
      final sm = build();
      await sm.recoverAndStart();
      sm.startTask('transfer');
      sm.endTaskCompleted('transfer');

      final keys = tasks().single.attributes.keys;
      expect(keys.where((k) => k.contains('apdex')), isEmpty);
      // No client-side banding of any spelling: the threshold is query-time and
      // per-target, so a band on the wire would need a client release to move.
      for (final banned in ['task.band', 'task.satisfied', 'task.slow']) {
        expect(keys, isNot(contains(banned)));
      }
    });

    test('a duplicate start supersedes — the second one is the live task',
        () async {
      final sm = build();
      await sm.recoverAndStart();

      sm.startTask('transfer');
      clock = clock.add(const Duration(minutes: 5));
      sm.startTask('transfer'); // the user restarted the journey
      clock = clock.add(const Duration(minutes: 1));
      sm.endTaskCompleted('transfer');

      expect(tasks(), hasLength(1));
      expect(tasks().single.attributes['span.duration_ms'],
          const Duration(minutes: 1).inMilliseconds.toString());
    });

    test('fire-and-forget: an unknown or already-closed name is a no-op',
        () async {
      final sm = build();
      await sm.recoverAndStart();

      sm.endTaskCompleted('never_started');
      expect(tasks(), isEmpty);

      sm.startTask('transfer');
      sm.endTaskCompleted('transfer');
      sm.endTaskCompleted('transfer');
      sm.endTask('transfer', TaskOutcome.failed);
      expect(tasks(), hasLength(1));
    });
  });

  group('trace context freezes at task start, and a task mints no root', () {
    test('the terminal carries the root live at the *start*', () async {
      final sm = build();
      await sm.recoverAndStart();
      final trace = TraceManager(session: sm, clock: () => clock);

      // The journey begins in a tap. This is what the facade does: freeze here,
      // carry the frozen copy to the terminal minutes later.
      trace.mint(TraceRootType.interaction);
      final startRoot = trace.current()['trace.id'];
      sm.startTask('transfer', trace.startChild()!.attributes);

      // Four minutes later: the 10 s root cap has long since aged that root
      // out, and an unrelated tap is now the live one.
      clock = clock.add(const Duration(minutes: 4));
      trace.mint(TraceRootType.interaction);
      expect(trace.current()['trace.id'], isNot(startRoot));

      sm.endTaskCompleted('transfer');

      final e = tasks().single;
      // The tap that *began* the journey, not the one open at the terminal.
      expect(e.attributes['trace.id'], startRoot);
      expect(e.attributes['trace.root_type'], 'interaction');
      expect(e.attributes['span.id'], isNotNull);
      expect(e.attributes['parent.span.id'], isNotNull);
      // And the Collector will strip the ambient keys before merging these.
      expect(e.ownsTraceContext, isTrue);
    });

    test('a task with no live root mints none and stays unattributed',
        () async {
      final sm = build();
      await sm.recoverAndStart();
      final trace = TraceManager(session: sm, clock: () => clock);

      // No root open → the facade's `startChild()` is null → empty trace bag.
      expect(trace.startChild(), isNull);
      final actionsBefore = sm.getSessionStats()['actionCount'];
      sm.startTask('nightly_sync', trace.startChild()?.attributes ?? const {});
      clock = clock.add(const Duration(seconds: 30));
      sm.endTaskCompleted('nightly_sync');

      final e = tasks().single;
      for (final k in kAmbientTraceAttributes) {
        expect(e.attributes.containsKey(k), isFalse);
      }
      expect(e.attributes.containsKey('span.id'), isFalse);
      // A root would have bumped session.action_count. None was minted.
      expect(sm.getSessionStats()['actionCount'], actionsBefore);
      // …and the duration still ships: an untraced task has no second
      // duration key to fall back on.
      expect(e.attributes['span.duration_ms'],
          const Duration(seconds: 30).inMilliseconds.toString());
    });
  });

  group('abandonment fires on session finalize only', () {
    test('navigating away is not a trigger — a transfer spans four routes',
        () async {
      final sm = build();
      await sm.recoverAndStart();
      sm.startTask('transfer');

      for (final screen in ['/amount', '/recipient', '/otp', '/receipt']) {
        sm.recordScreen(screen);
        clock = clock.add(const Duration(seconds: 20));
        sm.beforeEvent();
      }
      expect(tasks(), isEmpty);

      sm.endTaskCompleted('transfer');
      expect(tasks().single.attributes['task.outcome'],
          TaskOutcome.completed.name);
    });

    test('backgrounding is not a trigger — reading the OTP is step 2',
        () async {
      final sm = build();
      await sm.recoverAndStart();
      sm.startTask('transfer');

      clock = clock.add(const Duration(seconds: 30));
      sm.handlePause(); // switch to the SMS app
      clock = clock.add(const Duration(seconds: 40));
      sm.handleResume(); // well inside the idle window
      expect(tasks(), isEmpty);

      sm.endTaskCompleted('transfer');
      expect(tasks().single.attributes['task.outcome'],
          TaskOutcome.completed.name);
    });

    test('the idle rotation abandons, measured to last activity not wall-clock',
        () async {
      final sm = build();
      await sm.recoverAndStart(); // session_1 @ 09:00
      sm.startTask('onboarding');

      clock = clock.add(const Duration(minutes: 2)); // 09:02
      sm.beforeEvent(); // last activity @ 09:02

      clock = clock.add(const Duration(minutes: 40)); // 09:42, idle exceeded
      sm.beforeEvent();

      final e = tasks().single;
      expect(e.attributes['task.outcome'], TaskOutcome.abandoned.name);
      expect(e.attributes['task.abandon_source'],
          TaskAbandonSource.sessionEnd.wire);
      expect(e.attributes['session.id'], 'session_1');
      // start (09:00) → last activity (09:02), not → finalize (09:42).
      expect(e.attributes['span.duration_ms'],
          const Duration(minutes: 2).inMilliseconds.toString());

      // The abandon precedes the bookend of the session it belongs to.
      final names = emitted.map((e) => e.name).toList();
      expect(names.indexOf('task.complete'),
          lessThan(names.indexOf('session.finalized')));

      // …and the rotation cleared it: no second abandon next time round.
      emitted.clear();
      clock = clock.add(const Duration(minutes: 40));
      sm.beforeEvent();
      expect(tasks(), isEmpty);
    });

    test('a start after a long idle rotates first, so it is not abandoned at 0',
        () async {
      final sm = build();
      await sm.recoverAndStart(); // session_1 @ 09:00

      // 40 minutes of foreground idle: no events, so nothing has rotated yet.
      clock = clock.add(const Duration(minutes: 40));
      sm.startTask('transfer');

      // The start rotated the session itself, so the task belongs to the live
      // one — it is not swept up by the rotation the next event would cause.
      expect(tasks(), isEmpty);
      clock = clock.add(const Duration(minutes: 2));
      sm.beforeEvent();
      expect(tasks(), isEmpty);

      sm.endTaskCompleted('transfer');
      expect(tasks().single.attributes['task.outcome'],
          TaskOutcome.completed.name);
      expect(tasks().single.attributes['span.duration_ms'],
          const Duration(minutes: 2).inMilliseconds.toString());
    });

    test('a rotation at the start drops the dying session\'s trace context',
        () async {
      final sm = build();
      await sm.recoverAndStart(); // session_1 @ 09:00
      final trace = TraceManager(session: sm, clock: () => clock);
      trace.mint(TraceRootType.interaction);

      // 40 minutes idle, then the facade's order: rotate, *then* freeze. The
      // stale root belongs to session_1, so `startChild` finds it cleared.
      clock = clock.add(const Duration(minutes: 40));
      sm.beforeEvent();
      final frozen = trace.startChild();
      expect(frozen, isNull, reason: 'a trace never spans a session');
      sm.startTask('transfer', frozen?.attributes ?? const {});
      sm.endTaskCompleted('transfer');

      // Unattributed rather than attributed to the session that ended.
      final e = tasks().single;
      for (final k in kAmbientTraceAttributes) {
        expect(e.attributes.containsKey(k), isFalse);
      }
    });

    test('there is no task TTL of its own — only the session idle window',
        () async {
      final sm = build();
      await sm.recoverAndStart();
      sm.startTask('onboarding');

      // 25 minutes of real activity: far past every other TTL in the SDK
      // (the 10 s root cap, the 2 s idle window) and still not abandoned.
      for (var i = 0; i < 5; i++) {
        clock = clock.add(const Duration(minutes: 5));
        sm.beforeEvent();
      }
      expect(tasks(), isEmpty);
    });
  });

  test('a startTask re-entered from the abandon emit does not blow up',
      () async {
    late SessionManager sm;
    var reentered = false;
    sm = SessionManager(
      emit: (e) {
        emitted.add(e);
        // A consumer callback on the wire path that declares a new task while
        // the finalize is still iterating the open ones.
        if (e.name == 'task.complete' && !reentered) {
          reentered = true;
          sm.startTask('reentrant');
        }
      },
      newSessionId: () => 'session_${++ids}',
      clock: () => clock,
      idleTimeout: idle,
    );
    await sm.recoverAndStart();
    sm.startTask('a');
    sm.startTask('b');

    clock = clock.add(const Duration(minutes: 40));
    expect(sm.beforeEvent, returnsNormally);
    expect(tasks().where((e) => e.attributes['task.outcome'] == 'abandoned'),
        hasLength(2));
  });

  group('kill recovery', () {
    test('an open task survives the pause write and abandons on next launch',
        () async {
      final sm1 = build();
      await sm1.recoverAndStart(); // session_1 @ 09:00
      sm1.startTask('transfer', {
        'trace.id': 'a' * 32,
        'rum.action.id': 'b' * 16,
        'trace.root_type': 'interaction',
        'span.id': 'c' * 16,
        'parent.span.id': 'b' * 16,
      });

      clock = clock.add(const Duration(minutes: 4)); // 09:04
      sm1.handlePause(); // the record now holds the open task
      clock = clock.add(const Duration(hours: 2)); // killed, then relaunched

      emitted = [];
      final sm2 = build();
      await sm2.recoverAndStart();

      final e = tasks().single;
      expect(e.attributes['task.name'], 'transfer');
      expect(e.attributes['task.outcome'], TaskOutcome.abandoned.name);
      // The gap is stated, not hidden: at this instant native crashes have not
      // been drained, so a crash and an OS kill are indistinguishable.
      expect(e.attributes['task.abandon_source'],
          TaskAbandonSource.launchRecovery.wire);
      // Attribution intact — the ids frozen in the process that died.
      expect(e.attributes['session.id'], 'session_1');
      expect(e.attributes['trace.id'], 'a' * 32);
      expect(e.attributes['rum.action.id'], 'b' * 16);
      expect(e.attributes['span.id'], 'c' * 16);
      expect(e.attributes['parent.span.id'], 'b' * 16);
      // Believable: 4 minutes to the last activity, not 2h04 of wall-clock.
      expect(e.attributes['span.duration_ms'],
          const Duration(minutes: 4).inMilliseconds.toString());
    });

    test('a closed task is not re-reported as abandoned after a crash',
        () async {
      final sm1 = build();
      await sm1.recoverAndStart();
      sm1.startTask('transfer');
      clock = clock.add(const Duration(minutes: 1));
      sm1.handlePause();
      sm1.handleResume();
      clock = clock.add(const Duration(minutes: 1));
      sm1.endTaskCompleted(
          'transfer'); // closed *after* the last lifecycle edge
      // …then a foreground crash: no `paused`, so no further lifecycle write.

      emitted = [];
      await build().recoverAndStart();
      expect(tasks(), isEmpty);
    });

    test('a corrupt tasks block is skipped, not thrown', () async {
      SharedPreferences.setMockInitialValues({
        recordKey: '{"id":"session_old","start":"2026-01-01T08:00:00.000",'
            '"lastActivity":"2026-01-01T08:30:00.000",'
            '"tasks":{"ok":{"start":"2026-01-01T08:05:00.000"},'
            '"no_start":{},"wrong_shape":"nope"}}',
      });

      await build().recoverAndStart();

      expect(tasks(), hasLength(1));
      expect(tasks().single.attributes['task.name'], 'ok');
      expect(emitted.where((e) => e.name == 'session.finalized'), hasLength(1));
    });
  });

  test('wire seam: the recovered abandonment lands in a batch, joinable',
      () async {
    // A record left behind by a process that died mid-transfer.
    SharedPreferences.setMockInitialValues({
      recordKey: '{"id":"session_dead","start":"2026-01-01T08:00:00.000Z",'
          '"lastActivity":"2026-01-01T08:06:00.000Z",'
          '"tasks":{"transfer":{"start":"2026-01-01T08:01:00.000Z",'
          '"trace":{"trace.id":"${'a' * 32}","rum.action.id":"${'b' * 16}",'
          '"trace.root_type":"interaction","span.id":"${'c' * 16}",'
          '"parent.span.id":"${'b' * 16}"}}}}',
    });

    final sender = _RecordingSender();
    final session = SessionManager(
      newSessionId: () => 'session_live',
      clock: () => clock,
      idleTimeout: idle,
    );
    final context =
        ContextManager(sessionManager: session, global: {'device.id': 'd_1'});
    final pipeline = Pipeline(
      transport: RetryTransport(
          endpoint: 'https://api.example.test',
          queue: _NoopQueue(),
          sender: sender.call),
      batchSize: 100,
    );
    final collector =
        Collector(context: context, session: session, pipeline: pipeline);
    session.bindSink(collector);

    await session.recoverAndStart();
    pipeline.flush();

    final item =
        sender.items.singleWhere((i) => i['eventName'] == 'task.complete');
    final attrs = (item['attributes'] as Map).cast<String, String>();

    expect(attrs['task.name'], 'transfer');
    expect(attrs['task.outcome'], TaskOutcome.abandoned.name);
    expect(attrs['task.abandon_source'], TaskAbandonSource.launchRecovery.wire);
    // Joins to the session that ended, not the one that just started — the
    // whole reason the id rides the item's own bag.
    expect(attrs['session.id'], 'session_dead');
    expect(attrs['trace.id'], 'a' * 32);
    expect(attrs['span.id'], 'c' * 16);
    // 08:01 → 08:06 last activity.
    expect(attrs['span.duration_ms'],
        const Duration(minutes: 5).inMilliseconds.toString());
    // The SDK context still rides it, so the row is not an orphan.
    expect(attrs['device.id'], 'd_1');

    // The closing leg over the same seam: it takes its session id from the
    // snapshot, so it joins the session that is actually live.
    session.startTask('checkout');
    clock = clock.add(const Duration(minutes: 2));
    session.endTask('checkout', TaskOutcome.completed);
    pipeline.flush();

    final done =
        sender.items.lastWhere((i) => i['eventName'] == 'task.complete');
    final doneAttrs = (done['attributes'] as Map).cast<String, String>();
    expect(doneAttrs['task.name'], 'checkout');
    expect(doneAttrs['task.outcome'], TaskOutcome.completed.name);
    expect(doneAttrs['session.id'], 'session_live');
    expect(doneAttrs.containsKey('task.abandon_source'), isFalse);
    expect(doneAttrs['span.duration_ms'],
        const Duration(minutes: 2).inMilliseconds.toString());
  });
}
