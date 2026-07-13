// Tests for the timer-free lazy session model (ticket #24): idle rotation,
// pause/finalize, kill-recovery, and the journey summary on session.finalized.

import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const idle = Duration(minutes: 30);

  late List<EdgeEvent> emitted;
  late DateTime clock;
  late int idCounter;

  SessionManager build() => SessionManager(
        emit: emitted.add,
        newSessionId: () => 'session_${++idCounter}',
        clock: () => clock,
        idleTimeout: idle,
      );

  Map<String, String> attrsOf(EdgeEvent e) => e.attributes;
  Iterable<EdgeEvent> named(String name) =>
      emitted.where((e) => e.name == name);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    emitted = [];
    clock = DateTime(2026, 1, 1, 9, 0, 0);
    idCounter = 0;
  });

  group('start', () {
    test('recoverAndStart emits one immediate session.started', () async {
      await build().recoverAndStart();

      final started = named('session.started').toList();
      expect(started, hasLength(1));
      expect(started.single.priority, EventPriority.immediate);
      expect(attrsOf(started.single)['session.id'], 'session_1');
      expect(named('session.finalized'), isEmpty); // nothing to recover
    });
  });

  group('lazy idle rotation (no timer)', () {
    test('beforeEvent past the window finalizes (backdated) + starts fresh',
        () async {
      final sm = build();
      await sm.recoverAndStart(); // session_1 @ 09:00

      clock = clock.add(const Duration(minutes: 5));
      sm.beforeEvent(); // activity @ 09:05, no rotation
      expect(named('session.finalized'), isEmpty);

      clock = clock.add(const Duration(minutes: 35)); // 09:40, 35min idle
      sm.beforeEvent();

      final fin = named('session.finalized').single;
      expect(attrsOf(fin)['session.id'], 'session_1');
      // Backdated end == last activity (09:05), not now (09:40).
      expect(attrsOf(fin)['session.end_time'],
          DateTime(2026, 1, 1, 9, 5).toIso8601String());
      expect(attrsOf(fin)['session.duration_ms'],
          const Duration(minutes: 5).inMilliseconds.toString());

      expect(named('session.started').map((e) => attrsOf(e)['session.id']),
          ['session_1', 'session_2']);
    });

    test('beforeEvent within the window does not rotate', () async {
      final sm = build();
      await sm.recoverAndStart();

      clock = clock.add(const Duration(minutes: 29));
      sm.beforeEvent();

      expect(named('session.finalized'), isEmpty);
      expect(sm.currentSessionId, 'session_1');
    });
  });

  group('pause / resume', () {
    test('pause marks without finalizing; resume within window continues',
        () async {
      final sm = build();
      await sm.recoverAndStart();

      clock = clock.add(const Duration(minutes: 10));
      sm.handlePause();
      expect(named('session.finalized'), isEmpty);

      clock = clock.add(const Duration(minutes: 10)); // 20min backgrounded
      sm.handleResume();

      expect(named('session.finalized'), isEmpty);
      expect(sm.currentSessionId, 'session_1');
    });

    test('resume after idle finalizes backdated to background time', () async {
      final sm = build();
      await sm.recoverAndStart();

      clock = clock.add(const Duration(minutes: 2));
      sm.handlePause(); // background @ 09:02

      clock = clock.add(const Duration(minutes: 45)); // 45min later
      sm.handleResume();

      final fin = named('session.finalized').single;
      expect(attrsOf(fin)['session.id'], 'session_1');
      expect(attrsOf(fin)['session.end_time'],
          DateTime(2026, 1, 1, 9, 2).toIso8601String());
      expect(sm.currentSessionId, 'session_2');
    });
  });

  group('kill-recovery', () {
    test('a persisted killed session is finalized backdated on next launch',
        () async {
      // Launch 1: run, record activity, background (persists the record), then
      // the process is killed (no clean finalize).
      final sm1 = build();
      await sm1.recoverAndStart();
      sm1.recordScreen('/home');
      sm1.recordHttpRequest();
      clock = clock.add(const Duration(minutes: 3));
      sm1.handlePause(); // persists lastActivity @ 09:03

      // Launch 2: fresh manager, later clock. Recovery finalizes session_1.
      emitted = [];
      idCounter = 100;
      clock = DateTime(2026, 1, 1, 12, 0, 0);
      final sm2 = build();
      await sm2.recoverAndStart();

      final fin = named('session.finalized').single;
      expect(attrsOf(fin)['session.id'], 'session_1');
      expect(attrsOf(fin)['session.recovered'], 'true');
      expect(attrsOf(fin)['session.end_time'],
          DateTime(2026, 1, 1, 9, 3).toIso8601String());
      expect(attrsOf(fin)['session.http_request_count'], '1');
      expect(attrsOf(fin)['session.screen_count'], '1');
      expect(attrsOf(fin)['session.screen_journey'], '/home');

      // A brand-new session is live afterwards.
      expect(sm2.currentSessionId, 'session_101');
    });
  });

  group('journey summary', () {
    test('counts and 20-hop-capped screen_journey', () async {
      final sm = build();
      await sm.recoverAndStart();

      sm.recordEvent();
      sm.recordEvent();
      sm.recordCrash();
      sm.recordError();
      sm.recordHttpRequest();
      sm.recordHttpRequest();
      sm.recordHttpRequest();
      for (var i = 0; i < 25; i++) {
        sm.recordScreen('/s$i');
      }

      clock = clock.add(const Duration(minutes: 31));
      sm.beforeEvent(); // rotate → finalize session_1

      final fin = named('session.finalized').single;
      final a = attrsOf(fin);
      expect(a['session.event_count'], '2');
      expect(a['session.crash_count'], '1');
      expect(a['session.error_count'], '1');
      expect(a['session.http_request_count'], '3');
      expect(a['session.screen_count'], '25');

      final journey = a['session.screen_journey']!.split('>');
      expect(journey, hasLength(20)); // last 20 hops only
      expect(journey.first, '/s5');
      expect(journey.last, '/s24');
    });
  });
}
