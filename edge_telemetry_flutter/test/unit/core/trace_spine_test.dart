// test/unit/core/trace_spine_test.dart
//
// The correlation spine (#83). Two halves, and the second is the load-bearing
// one: the id generator must never produce a value `edge_db`'s CHECK rejects
// (a short or all-zero id dead-letters the whole event, not just its trace),
// and the ambient keys must reach items that never touch trace context — which
// is the structural fix for the bug class that silently dropped seven
// emissions through all of v2.

import 'package:edge_telemetry_flutter/src/capture/lifecycle_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/core/wire_canon.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/identity_format.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/trace_manager.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];

  /// Wire items, unwrapped from their `telemetry_batch` envelope.
  List<Map<String, dynamic>> get items => [
        for (final p in sent)
          ...?(p['events'] as List?)?.cast<Map<String, dynamic>>()
      ];

  Map<String, String> attributesOf(String eventName) =>
      (items.firstWhere((i) => i['eventName'] == eventName)['attributes']
              as Map)
          .cast<String, String>();

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

/// One assembled stack in the strict construction order the facade uses:
/// session → trace → context → collector → recorded wire.
class _Rig {
  _Rig({DateTime Function()? clock}) {
    session = SessionManager(
      clock: clock,
      newSessionId: () => 'session_rotated_${++_rotations}',
    );
    trace = TraceManager(session: session, clock: clock);
    context = ContextManager(
      sessionManager: session,
      trace: trace,
      global: {'device.id': 'device_1', 'user.id': 'user_1'},
    );
    pipeline = Pipeline(
      transport: RetryTransport(
          endpoint: 'https://example.test',
          queue: _NoopQueue(),
          sender: sender.call),
      batchSize: 50,
    );
    collector =
        Collector(context: context, session: session, pipeline: pipeline);
  }

  int _rotations = 0;
  final sender = _RecordingSender();
  late final SessionManager session;
  late final TraceManager trace;
  late final ContextManager context;
  late final Pipeline pipeline;
  late final Collector collector;

  void flush() => pipeline.flush();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('id generation', () {
    test('widths are exact and the values are CHECK-conformant hex', () {
      // 200 draws: enough that a mis-padded generator would show a short one.
      for (var i = 0; i < 200; i++) {
        expect(secureHex32(), matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(secureHex16(), matches(RegExp(r'^[0-9a-f]{16}$')));
      }
    });

    test('never all-zero — the guard is explicit, not statistical', () {
      // A 1-nibble id makes the all-zero case fire 1-in-16 per draw, so an
      // absent guard fails this within a handful of iterations.
      for (var i = 0; i < 500; i++) {
        expect(secureHex(1), isNot('0'));
      }
    });
  });

  group('root lifetime', () {
    test('mint opens a root; the three ambient keys and only those', () {
      final rig = _Rig();
      rig.trace.mint(TraceRootType.launch);

      final ambient = rig.trace.current();
      expect(ambient.keys.toSet(), kAmbientTraceAttributes);
      expect(ambient['trace.id'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(ambient['rum.action.id'], matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(ambient['trace.root_type'], 'launch');
    });

    test('a second mint supersedes the first outright', () {
      final rig = _Rig();
      rig.trace.mint(TraceRootType.launch);
      final first = rig.trace.current();
      rig.trace.mint(TraceRootType.interaction);
      final second = rig.trace.current();

      expect(second['trace.id'], isNot(first['trace.id']));
      expect(second['rum.action.id'], isNot(first['rum.action.id']));
      expect(second['trace.root_type'], 'interaction');
    });

    test('expires on the idle window, in the read accessor', () {
      var now = DateTime(2026, 1, 1, 12);
      final rig = _Rig(clock: () => now);
      rig.trace.mint(TraceRootType.interaction);

      now = now.add(TraceManager.idleWindow + const Duration(milliseconds: 1));
      expect(rig.trace.current(), isEmpty);
      expect(rig.trace.startChild(), isNull);
    });

    test('a child span extends the idle window; the hard cap still ends it',
        () {
      var now = DateTime(2026, 1, 1, 12);
      final rig = _Rig(clock: () => now);
      rig.trace.mint(TraceRootType.interaction);
      final traceId = rig.trace.current()['trace.id'];

      // Six 1.5 s steps, each with a child span: 9 s of activity that would
      // have aged out six times over on idle alone.
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(milliseconds: 1500));
        expect(rig.trace.startChild(), isNotNull);
      }
      expect(rig.trace.current()['trace.id'], traceId);

      // Past 10 s from the mint, the cap ends it regardless of activity.
      now = now.add(const Duration(milliseconds: 1500));
      expect(rig.trace.startChild(), isNull);
    });

    test('clear() drops the root — the load-bearing pause path', () {
      final rig = _Rig();
      rig.trace.mint(TraceRootType.launch);
      rig.trace.clear();
      expect(rig.trace.current(), isEmpty);
    });
  });

  group('startChild', () {
    test('freezes one immutable record: child span, parent link, session',
        () async {
      final rig = _Rig();
      await rig.session.startSession('session_1');
      rig.trace.mint(TraceRootType.interaction);
      final ambient = rig.trace.current();

      final frozen = rig.trace.startChild()!;
      expect(frozen.traceId, ambient['trace.id']);
      expect(frozen.spanId, matches(RegExp(r'^[0-9a-f]{16}$')));
      // The root's span id under both names: `rum.action.id` is the join key,
      // `parent.span.id` the tree pointer. Never an independent identifier.
      expect(frozen.parentSpanId, ambient['rum.action.id']);
      expect(frozen.attributes['rum.action.id'], frozen.parentSpanId);
      expect(frozen.attributes['parent.span.id'], frozen.parentSpanId);
      expect(frozen.rootType, TraceRootType.interaction);
      expect(frozen.sessionId, 'session_1');
    });

    test('every child gets its own span id; the root span id does not move',
        () {
      final rig = _Rig();
      rig.trace.mint(TraceRootType.interaction);
      final a = rig.trace.startChild()!;
      final b = rig.trace.startChild()!;

      expect(a.spanId, isNot(b.spanId));
      expect(a.parentSpanId, b.parentSpanId);
    });

    test('null when no root is open — the legal unattributed case', () {
      expect(_Rig().trace.startChild(), isNull);
    });
  });

  group('wire seam', () {
    test('ambient keys land on an event that never touches trace context',
        () async {
      final rig = _Rig();
      await rig.session.startSession('session_1');
      rig.trace.mint(TraceRootType.launch);

      // network_change is emitted by a hook with no knowledge of tracing.
      rig.collector.add(const EdgeEvent.event('network_change',
          attributes: {'network.type': 'wifi'}));
      rig.flush();

      final attrs = rig.sender.attributesOf('network_change');
      expect(attrs['trace.id'], isNotNull);
      expect(attrs['rum.action.id'], isNotNull);
      expect(attrs['trace.root_type'], 'launch');
      // Never ambient: they are minted per referenceable item.
      expect(attrs.containsKey('span.id'), isFalse);
      expect(attrs.containsKey('parent.span.id'), isFalse);
    });

    test('ownsTraceContext strips exactly the three ambient keys', () async {
      final rig = _Rig();
      await rig.session.startSession('session_1');
      rig.trace.mint(TraceRootType.launch);
      final frozen = rig.trace.startChild()!;

      // Supersede: by the time the request completes, a tap owns the context.
      rig.trace.mint(TraceRootType.interaction);
      final live = rig.trace.current();

      rig.collector.add(EdgeEvent.event('http.request',
          ownsTraceContext: true,
          attributes: {
            'http.url': 'https://api.test/v1',
            ...frozen.attributes
          }));
      rig.flush();

      final attrs = rig.sender.attributesOf('http.request');
      expect(attrs['trace.id'], frozen.traceId);
      expect(attrs['rum.action.id'], frozen.parentSpanId);
      expect(attrs['trace.root_type'], 'launch');
      expect(attrs['span.id'], frozen.spanId);
      // The live root leaked nothing.
      expect(attrs['trace.id'], isNot(live['trace.id']));
      // Everything outside the three keys still spreads normally.
      expect(attrs['session.id'], 'session_1');
      expect(attrs['device.id'], 'device_1');
    });

    test(
        'a frozen-empty item carries no trace keys — absence cannot lose to a '
        'later tap', () async {
      final rig = _Rig();
      await rig.session.startSession('session_1');

      // Frozen with no root live: legally unattributed, so no trace keys.
      expect(rig.trace.startChild(), isNull);

      // A tap 50 ms later opens one, and the request completes after it.
      rig.trace.mint(TraceRootType.interaction);

      rig.collector.add(const EdgeEvent.event('http.request',
          ownsTraceContext: true,
          attributes: {'http.url': 'https://api.test/v1'}));
      rig.flush();

      final attrs = rig.sender.attributesOf('http.request');
      for (final key in kAmbientTraceAttributes) {
        expect(attrs.containsKey(key), isFalse,
            reason: '$key was stamped onto a request that started before it');
      }
    });

    test('trace context clears on AppLifecycleState.paused', () async {
      final rig = _Rig();
      await rig.session.startSession('session_1');
      rig.trace.mint(TraceRootType.interaction);

      // The always-on lifecycle hook, clearing beside its session pause.
      LifecycleCaptureHook(
        session: rig.session,
        trace: rig.trace,
        flush: rig.flush,
      )
        ..start(rig.collector)
        ..didChangeAppLifecycleState(AppLifecycleState.paused);

      expect(rig.trace.current(), isEmpty);
      // The session itself is only marked, never finalized, by a pause.
      expect(rig.session.currentSessionId, 'session_1');
    });

    test('trace context clears on session rotation', () async {
      var now = DateTime(2026, 1, 1, 12);
      final rig = _Rig(clock: () => now);
      await rig.session.startSession('session_1');
      rig.trace.mint(TraceRootType.interaction);
      expect(rig.trace.current(), isNotEmpty);

      // Past the idle window → the next event rotates the session.
      now = now.add(const Duration(minutes: 31));
      rig.collector.add(const EdgeEvent.event('custom_event'));
      expect(rig.session.currentSessionId, 'session_rotated_1');

      // A trace never spans a session; no callback needed, the root's own
      // session id no longer matches the live one.
      expect(rig.trace.current(), isEmpty);
      rig.flush();
      final attrs = rig.sender.attributesOf('custom_event');
      for (final key in kAmbientTraceAttributes) {
        expect(attrs.containsKey(key), isFalse);
      }
    });
  });

  group('screen.id', () {
    test('minted per entry, on the snapshot, and a revisit is a new visit',
        () async {
      final rig = _Rig();
      await rig.session.startSession('session_1');

      rig.session.recordScreen('/home');
      final first = rig.session.currentScreenId;
      expect(first, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(rig.context.snapshot()['screen.id'], first);

      rig.session.recordScreen('/cart');
      rig.session.recordScreen('/home'); // back-navigation
      expect(rig.session.currentScreenId, isNot(first));
    });

    test('resets on session rotation', () async {
      var now = DateTime(2026, 1, 1, 12);
      final rig = _Rig(clock: () => now);
      await rig.session.startSession('session_1');
      rig.session.recordScreen('/home');
      expect(rig.session.currentScreenId, isNotNull);

      now = now.add(const Duration(minutes: 31));
      rig.collector.add(const EdgeEvent.event('custom_event'));

      expect(rig.session.currentScreenId, isNull);
      expect(rig.context.snapshot().containsKey('screen.id'), isFalse);
    });

    test('is per-item: the batch hoist must never lift it', () {
      expect(isHoistedContextKey('screen.id'), isFalse);
      for (final key in kAmbientTraceAttributes) {
        expect(isHoistedContextKey(key), isFalse,
            reason: '$key varies per item');
      }
    });
  });
}
