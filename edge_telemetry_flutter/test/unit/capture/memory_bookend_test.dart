import 'package:edge_telemetry_flutter/src/capture/capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/memory_bookend_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/perf_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/crash/native_crash_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingSink implements EventSink {
  final List<EdgeEvent> events = [];
  @override
  void add(EdgeEvent event) => events.add(event);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeCrashChannel.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late int reads;
  late List<String> flushes;

  void mockState(Map<String, dynamic>? state) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'readDeviceState') return null;
      reads++;
      return state;
    });
  }

  setUp(() {
    reads = 0;
    flushes = [];
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  MemoryBookendHook hookOn(_RecordingSink sink) => MemoryBookendHook(
        channel: NativeCrashChannel(),
        flush: () => flushes.add('flush'),
      )..start(sink);

  test('two items per session, one per bookend, and nothing in between',
      () async {
    mockState({'memory.used_bytes': '14237696', 'memory.source': 'pss'});
    final sink = _RecordingSink();
    final hook = hookOn(sink);

    hook.onSessionStart();
    await pumpEventQueue();
    expect(sink.events, hasLength(1), reason: 'opening bookend');

    hook.onPaused();
    await pumpEventQueue();
    expect(sink.events, hasLength(2), reason: 'closing bookend');

    final names = sink.events.map((e) => e.name).toSet();
    expect(names, {'memory_usage'});
    expect(sink.events.map((e) => e.attributes['memory.phase']),
        ['session_start', 'session_end']);
    expect(reads, 2, reason: 'no cache, and no third read');
    // The closing read resolves after the lifecycle hook's own flush has gone,
    // so the item it just added needs a flush of its own or it waits in the
    // buffer for a resume that may never come.
    expect(flushes, hasLength(1), reason: 'closing bookend only');
  });

  test(
      'the closing bookend fires once — a pause/resume round trip is not a '
      'new session', () async {
    mockState({'memory.used_bytes': '1', 'memory.source': 'footprint'});
    final sink = _RecordingSink();
    final hook = hookOn(sink);

    hook.onSessionStart();
    hook.onPaused();
    hook.onPaused();
    hook.onPaused();
    await pumpEventQueue();

    expect(sink.events, hasLength(2));
  });

  test('a rotation opens a fresh pair', () async {
    mockState({'memory.used_bytes': '1', 'memory.source': 'pss'});
    final sink = _RecordingSink();
    final hook = hookOn(sink);

    hook.onSessionStart();
    hook.onPaused();
    hook.onSessionStart(); // rotation
    hook.onPaused();
    await pumpEventQueue();

    expect(sink.events.map((e) => e.attributes['memory.phase']),
        ['session_start', 'session_end', 'session_start', 'session_end']);
  });

  test('the source key makes the native quantity legible on the wire',
      () async {
    mockState({'memory.used_bytes': '512', 'memory.source': 'footprint'});
    final sink = _RecordingSink();
    hookOn(sink).onSessionStart();
    await pumpEventQueue();

    final metric = sink.events.single;
    expect(metric.value, 512.0);
    expect(metric.attributes['memory.source'], 'footprint');
    expect(metric.attributes['memory.unit'], 'bytes');
    // v2's `memory.type: rss` described a quantity we no longer read.
    expect(metric.attributes.containsKey('memory.type'), isFalse);
  });

  test('no native plugin → no item, never a false zero', () async {
    // Missing plugin: the channel answers with MissingPluginException.
    final sink = _RecordingSink();
    hookOn(sink)
      ..onSessionStart()
      ..onPaused();
    await pumpEventQueue();

    expect(sink.events, isEmpty);
    expect(flushes, isEmpty, reason: 'nothing was added, so nothing to flush');
  });

  test('a native read with no memory key emits nothing', () async {
    // The fault bundle alone — an OEM build whose memory read threw.
    mockState({'device.thermal_state': 'serious'});
    final sink = _RecordingSink();
    hookOn(sink).onSessionStart();
    await pumpEventQueue();

    expect(sink.events, isEmpty);
  });

  testWidgets('PerfCaptureHook no longer runs a health time series',
      (tester) async {
    final sink = _RecordingSink();
    final dispose = PerfCaptureHook().start(sink);
    addTearDown(dispose);

    // v2 emitted `memory_usage` every 10 s and `performance.system_check`
    // every 30 s from here — ~58 items a session into a series nobody read.
    await tester.pump(const Duration(minutes: 2));

    final names = sink.events.map((e) => e.name).toSet();
    expect(names, isNot(contains('memory_usage')));
    expect(names, isNot(contains('performance.system_check')));
    expect(names, isNot(contains('performance.memory_pressure')));
    expect(names, isNot(contains('performance.monitor_initialized')));
  });
}
