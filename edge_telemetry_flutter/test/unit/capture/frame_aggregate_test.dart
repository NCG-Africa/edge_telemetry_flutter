// test/unit/capture/frame_aggregate_test.dart
//
// Wayfinder #89 — the windowed frame aggregate. Asserts the ten keys, the
// fixed thresholds, the boundary, the keep-worst-two reservoir's ranking, the
// frozen/backdated context, the redefined `long_task`, and the tier split.

import 'dart:ui' show FrameTiming;

import 'package:edge_telemetry_flutter/src/capture/capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/frame_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/core/capture_gate.dart';
import 'package:edge_telemetry_flutter/src/core/config/collection_tier.dart';
import 'package:edge_telemetry_flutter/src/core/config/telemetry_config.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSink implements EventSink {
  final List<EdgeEvent> events = [];

  @override
  void add(EdgeEvent event) => events.add(event);

  List<EdgeEvent> named(String name) =>
      events.where((e) => e.name == name).toList();
}

/// A frame finishing its raster at [atMicros] on the engine's monotonic clock,
/// whose `totalSpan` is [totalMs] — vsync start to raster finish, the quantity
/// the aggregate measures. `build` and `raster` are carved out of that span
/// deliberately overlapping, which is the pipelining that makes their sum the
/// wrong number.
FrameTiming _frame({
  required int atMicros,
  required double totalMs,
  double buildMs = 4,
  double rasterMs = 4,
}) {
  int us(double ms) => (ms * 1000).round();
  final vsyncStart = atMicros - us(totalMs);
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: vsyncStart + us(1),
    buildFinish: vsyncStart + us(1 + buildMs),
    rasterStart: atMicros - us(rasterMs),
    rasterFinish: atMicros,
    rasterFinishWallTime: atMicros,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SessionManager session;
  late _FakeSink sink;
  late FrameCaptureHook hook;
  late DisposeHandle dispose;
  late DateTime now;

  /// The engine's monotonic frame clock, advanced alongside [now].
  late int monoUs;

  /// `diagnostic` off, `standard` on — the default row.
  CaptureGate standardGate() => CaptureGate(
    const TelemetryConfig(
      endpoint: 'https://example.test',
      apiKey: 'k',
      serviceName: 'test',
      tier: CollectionTier.standard,
    ),
  );

  CaptureGate diagnosticGate({Map<Capture, bool> overrides = const {}}) =>
      CaptureGate(
        TelemetryConfig(
          endpoint: 'https://example.test',
          apiKey: 'k',
          serviceName: 'test',
          tier: CollectionTier.diagnostic,
          captureOverrides: overrides,
        ),
      );

  void startHook({CaptureGate? gate}) {
    hook = FrameCaptureHook(
      session: session,
      gate: gate,
      clock: () => now,
      refreshRate: () => 120,
    );
    dispose = hook.start(sink);
  }

  /// Feed [count] frames of [totalMs] each, advancing both clocks by [stepMs].
  void frames(
    int count, {
    required double totalMs,
    double buildMs = 4,
    double rasterMs = 4,
    int stepMs = 16,
  }) {
    for (var i = 0; i < count; i++) {
      now = now.add(Duration(milliseconds: stepMs));
      monoUs += stepMs * 1000;
      hook.recordFrame(
        _frame(
          atMicros: monoUs,
          totalMs: totalMs,
          buildMs: buildMs,
          rasterMs: rasterMs,
        ),
      );
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session = SessionManager();
    await session.startSession('s1');
    session.recordScreen('/home');
    sink = _FakeSink();
    now = DateTime(2026, 1, 1, 9, 0, 0);
    monoUs = 5000000;
    startHook();
  });

  tearDown(() => dispose());

  Map<String, String> onlySummary() {
    final items = sink.named('frame.summary');
    expect(items, hasLength(1));
    return items.single.attributes;
  }

  group('the ten keys', () {
    test('a janky window carries the sibling set, verbatim', () {
      frames(9, totalMs: 8, buildMs: 3, rasterMs: 4);
      frames(1, totalMs: 900, buildMs: 500, rasterMs: 300);
      hook.flushReservoir();

      final a = onlySummary();
      expect(a.keys.toSet(), {
        'frame.total_frames',
        'frame.slow_frames',
        'frame.frozen_frames',
        'frame.slow_frame_rate',
        'frame.max_total_duration_ms',
        'frame.max_build_duration_ms',
        'frame.max_raster_duration_ms',
        'frame.window_duration_ms',
        'display.refresh_rate',
        'screen.name',
        // Not an eleventh key: `screen.id` is already ambient on every item.
        // It rides here as the frozen override of the ambient one.
        'screen.id',
      });
      expect(a['frame.total_frames'], '10');
      expect(a['frame.slow_frames'], '1');
      expect(a['frame.frozen_frames'], '1');
      expect(a['frame.slow_frame_rate'], '0.1000');
      expect(a['frame.max_total_duration_ms'], '900.00');
      expect(a['frame.max_build_duration_ms'], '500.00');
      expect(a['frame.max_raster_duration_ms'], '300.00');
      expect(a['display.refresh_rate'], '120.0');
      expect(a['frame.window_duration_ms'], '144.00'); // 10 frames, 16 ms apart
      expect(a['screen.name'], '/home');
      expect(a['screen.id'], session.currentScreenId);
    });

    test('the aggregate is an event, not the metric envelope', () {
      frames(1, totalMs: 50);
      hook.flushReservoir();
      expect(sink.named('frame.summary').single.type, 'event');
      expect(sink.named('frame.summary').single.value, isNull);
    });
  });

  group('thresholds are fixed absolutes', () {
    test('slow is one frame budget, not one refresh period', () {
      // At the 120 Hz this hook is reading, a refresh-derived budget would be
      // 8.3 ms and these would all count as slow. They are not.
      frames(5, totalMs: 12);
      frames(1, totalMs: 20);
      hook.flushReservoir();
      expect(onlySummary()['frame.slow_frames'], '1');
    });

    test('frozen is 700 ms and a subset of slow', () {
      frames(1, totalMs: 699);
      frames(1, totalMs: 701);
      hook.flushReservoir();
      final a = onlySummary();
      expect(a['frame.slow_frames'], '2');
      expect(a['frame.frozen_frames'], '1');
    });

    test('total duration is the frame span, not build + raster', () {
      // build 10 + raster 10 = 20 would be slow; the real span is 12 and is
      // not. v2 summed the two pipelined durations and over-reported drops.
      frames(1, totalMs: 12, buildMs: 10, rasterMs: 10);
      hook.flushReservoir();
      expect(sink.named('frame.summary'), isEmpty);
    });
  });

  group('the window boundary', () {
    test('closes on a screen change', () {
      // Two frames per screen: the boundary is checked *after* the
      // accumulators, so the first frame reported after a navigation is the
      // outgoing screen's last frame — the timings callback lags the push by
      // one frame, which is exactly the frame it describes.
      frames(2, totalMs: 50);
      session.recordScreen('/details');
      frames(2, totalMs: 60);
      hook.flushReservoir();

      final items = sink.named('frame.summary');
      expect(items, hasLength(2));
      expect(
        items.map((e) => e.attributes['screen.name']),
        containsAll(<String>['/home', '/details']),
      );
    });

    test('closes at the 10 s cap with no screen change and no timer', () {
      frames(700, totalMs: 20, stepMs: 16); // 11.2 s of frames
      hook.flushReservoir();
      expect(sink.named('frame.summary').length, greaterThan(1));
      expect(
        sink
            .named('frame.summary')
            .map(
              (e) => double.parse(e.attributes['frame.window_duration_ms']!),
            ),
        // The cap is checked once per frame, so a window overshoots by at
        // most the one frame that crossed it.
        everyElement(lessThan(kFrameWindowCap.inMilliseconds + 17)),
      );
    });

    test('a smooth window is discarded by the eligibility floor', () {
      frames(50, totalMs: 8);
      hook.flushReservoir();
      expect(sink.events, isEmpty);
    });
  });

  group('keep-worst-two, ranked on absolute counts', () {
    test('a five-frame window cannot evict a six-hundred-frame one', () {
      // The rate pathology: 3/5 = 0.60 beats 200/600 = 0.33 on rate, and
      // loses on counts, which is the whole point.
      void window(int total, int slow, String screen) {
        session.recordScreen(screen);
        frames(slow, totalMs: 50, stepMs: 1);
        frames(total - slow, totalMs: 8, stepMs: 1);
      }

      window(600, 200, '/long');
      window(5, 3, '/short');
      window(400, 100, '/medium');
      hook.flushReservoir();

      final items = sink.named('frame.summary');
      expect(items, hasLength(2));
      expect(
        items.map((e) => e.attributes['screen.name']),
        containsAll(<String>['/long', '/medium']),
      );
      expect(
        items.map((e) => e.attributes['screen.name']),
        isNot(contains('/short')),
      );
    });

    test('frozen count outranks slow count', () {
      session.recordScreen('/frozen-one');
      frames(1, totalMs: 900);
      session.recordScreen('/slow-many');
      frames(40, totalMs: 50, stepMs: 1);
      session.recordScreen('/slow-few');
      frames(3, totalMs: 50, stepMs: 1);
      hook.flushReservoir();

      expect(
        sink.named('frame.summary').map((e) => e.attributes['screen.name']),
        containsAll(<String>['/frozen-one', '/slow-many']),
      );
    });

    test('the open window is ranked at flush, not dropped', () {
      session.recordScreen('/mild');
      frames(1, totalMs: 20, stepMs: 1);
      session.recordScreen('/worst');
      frames(30, totalMs: 900, stepMs: 1); // still open at flush
      hook.flushReservoir();

      expect(
        sink.named('frame.summary').map((e) => e.attributes['screen.name']),
        containsAll(<String>['/mild', '/worst']),
      );
    });

    test('flushing twice does not re-emit the survivors', () {
      frames(1, totalMs: 50);
      hook.flushReservoir();
      hook.flushReservoir();
      expect(sink.named('frame.summary'), hasLength(1));
    });
  });

  group('frozen context, backdated, untraced', () {
    test('screen keys are the window start, not the screen at flush', () {
      frames(1, totalMs: 900);
      session.recordScreen('/somewhere-else');
      frames(1, totalMs: 8);
      hook.flushReservoir();

      expect(
        sink.named('frame.summary').first.attributes['screen.name'],
        '/home',
      );
    });

    test('the timestamp is backdated to the window start', () {
      final windowStart = now;
      frames(1, totalMs: 900);
      now = now.add(const Duration(minutes: 4));
      hook.flushReservoir();

      final item = sink.named('frame.summary').single;
      expect(item.occurredAt, isNotNull);
      // Backdated to the first frame of the window, not to the flush.
      expect(
        item.occurredAt!.isBefore(windowStart.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('no trace keys at all — a window is not an action', () {
      frames(1, totalMs: 900);
      hook.flushReservoir();
      final item = sink.named('frame.summary').single;
      // Nothing frozen on the item...
      expect(
        item.attributes.keys.where((k) => k.startsWith('trace.')),
        isEmpty,
      );
      expect(item.attributes.containsKey('rum.action.id'), isFalse);
      expect(item.attributes.containsKey('span.id'), isFalse);
      // ...and the flag that makes the Collector strip the ambient ones too.
      expect(item.ownsTraceContext, isTrue);
    });
  });

  group('long_task is frozen frames only', () {
    test('nothing at the default tier, whatever the jank', () {
      startHook(gate: standardGate());
      frames(200, totalMs: 900, stepMs: 1);
      expect(sink.named('long_task'), isEmpty);
    });

    test('one per frozen frame at diagnostic, never per dropped frame', () {
      startHook(gate: diagnosticGate());
      frames(200, totalMs: 20, stepMs: 1); // dropped under v2's predicate
      expect(sink.named('long_task'), isEmpty);

      frames(3, totalMs: 900, stepMs: 1);
      final tasks = sink.named('long_task');
      expect(tasks, hasLength(3));
      expect(tasks.first.type, 'metric');
      expect(tasks.first.value, closeTo(900, 0.01));
      expect(tasks.first.attributes.containsKey('frame.severity'), isFalse);
      expect(tasks.first.attributes.containsKey('frame.target_fps'), isFalse);
    });

    test('the 100/session backstop still holds, and resets on rotation', () {
      startHook(gate: diagnosticGate());
      frames(kLongTaskCap + 20, totalMs: 900, stepMs: 1);
      expect(sink.named('long_task'), hasLength(kLongTaskCap));

      hook.resetForNewSession();
      frames(1, totalMs: 900, stepMs: 1);
      expect(sink.named('long_task'), hasLength(kLongTaskCap + 1));
    });
  });

  group('tiers split the emitter, never double it', () {
    test(
      'diagnostic emits every qualifying window on close, and only there',
      () {
        startHook(gate: diagnosticGate());
        for (final screen in ['/a', '/b', '/c', '/d']) {
          session.recordScreen(screen);
          frames(2, totalMs: 50, stepMs: 1);
        }
        // Three windows closed by a screen change, emitted as they closed.
        expect(sink.named('frame.summary'), hasLength(3));
        hook.flushReservoir();
        // The fourth, and no reservoir replay of the first three.
        expect(sink.named('frame.summary'), hasLength(4));
      },
    );

    test('screenWindowedFrames off leaves the reservoir in charge', () {
      startHook(
        gate: diagnosticGate(overrides: {Capture.screenWindowedFrames: false}),
      );
      for (final screen in ['/a', '/b', '/c', '/d']) {
        session.recordScreen(screen);
        frames(2, totalMs: 50, stepMs: 1);
      }
      expect(sink.named('frame.summary'), isEmpty);
      hook.flushReservoir();
      expect(sink.named('frame.summary'), hasLength(2));
    });
  });

  group('the reservoir survives a pause', () {
    test('a resumed session neither re-sends nor re-ranks from empty', () {
      session.recordScreen('/mild');
      frames(4, totalMs: 20, stepMs: 1);
      hook.flushReservoir(); // backgrounded
      expect(sink.named('frame.summary'), hasLength(1));

      // Resumed, and nothing worse happens: no second copy of the same window.
      session.recordScreen('/also-mild');
      frames(2, totalMs: 20, stepMs: 1);
      hook.flushReservoir();
      final afterResume = sink.named('frame.summary');
      expect(afterResume, hasLength(2));
      expect(
        afterResume.map((e) => e.attributes['screen.name']),
        containsAll(<String>['/mild', '/also-mild']),
      );

      // A third, milder window cannot displace either incumbent, so it costs
      // no item at all.
      session.recordScreen('/mildest');
      frames(2, totalMs: 17, stepMs: 1);
      hook.flushReservoir();
      expect(sink.named('frame.summary'), hasLength(2));
    });

    test('a post-resume window only costs an item by being worse', () {
      frames(2, totalMs: 20, stepMs: 1);
      hook.flushReservoir();
      expect(sink.named('frame.summary'), hasLength(1));

      session.recordScreen('/the-real-worst');
      frames(40, totalMs: 900, stepMs: 1);
      hook.flushReservoir();
      final items = sink.named('frame.summary');
      expect(items, hasLength(2));
      expect(items.last.attributes['screen.name'], '/the-real-worst');
    });

    test('a session rotation empties the reservoir', () {
      frames(2, totalMs: 20, stepMs: 1);
      hook.flushReservoir();
      hook.resetForNewSession();

      session.recordScreen('/next-session');
      frames(2, totalMs: 20, stepMs: 1);
      hook.flushReservoir();
      final items = sink.named('frame.summary');
      expect(items, hasLength(2));
      expect(items.last.attributes['screen.name'], '/next-session');
    });
  });

  group('long_task is independent of the aggregate', () {
    test(
      'frames off, longTask on: the metric still fires, no summary does',
      () {
        hook = FrameCaptureHook(
          session: session,
          gate: diagnosticGate(overrides: {Capture.frames: false}),
          aggregate: false,
          clock: () => now,
          refreshRate: () => 120,
        );
        dispose = hook.start(sink);

        frames(3, totalMs: 900, stepMs: 1);
        hook.flushReservoir();
        expect(sink.named('long_task'), hasLength(3));
        expect(sink.named('frame.summary'), isEmpty);
      },
    );
  });

  group('an unknown refresh rate is omitted, never zeroed', () {
    test('no view reporting a rate leaves the key off entirely', () {
      hook = FrameCaptureHook(
        session: session,
        clock: () => now,
        refreshRate: () => null,
      );
      dispose = hook.start(sink);

      frames(2, totalMs: 900, stepMs: 1);
      hook.flushReservoir();
      expect(onlySummary().containsKey('display.refresh_rate'), isFalse);
    });
  });

  group('the wire seam', () {
    test('one bad window among many produces exactly two items, and the bad '
        'window is one of them', () {
      for (var i = 0; i < 20; i++) {
        session.recordScreen('/smooth-$i');
        frames(120, totalMs: 8, stepMs: 1);
      }
      session.recordScreen('/the-bad-one');
      frames(30, totalMs: 900, stepMs: 1);
      for (var i = 0; i < 5; i++) {
        session.recordScreen('/also-smooth-$i');
        frames(120, totalMs: 8, stepMs: 1);
      }
      // One mildly janky window, so there is a second survivor to rank.
      session.recordScreen('/mild');
      frames(10, totalMs: 20, stepMs: 1);
      hook.flushReservoir();

      final items = sink.named('frame.summary');
      expect(items, hasLength(2));
      expect(
        items.map((e) => e.attributes['screen.name']),
        contains('/the-bad-one'),
      );
    });

    test('a session with no slow frames emits nothing at all', () {
      for (var i = 0; i < 10; i++) {
        session.recordScreen('/s$i');
        frames(120, totalMs: 8, stepMs: 1);
      }
      hook.flushReservoir();
      expect(sink.events, isEmpty);
    });
  });
}
