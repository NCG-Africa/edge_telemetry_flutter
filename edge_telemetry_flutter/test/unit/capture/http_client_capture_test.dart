// test/unit/capture/http_client_capture_test.dart
//
// The wrapper seam (#87), driven through the real `HttpCaptureHook` against a
// real loopback server. The degenerate answers (already captured, pre-init,
// capture off) are assertions about *identity* — the call returns the argument
// itself — which is only checkable because the call returns the type it takes.
//
// The `dart:io` override is deliberately uninstalled throughout: this seam
// exists for clients that never reach one, so leaving both live would measure
// the other seam and hide this one.

import 'dart:async';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/capture/capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/http_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/http_client_capture.dart';
import 'package:edge_telemetry_flutter/src/capture/http_overrides.dart';
import 'package:edge_telemetry_flutter/src/capture/trace_injection.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/http_seam_state.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/trace_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSink sink;
  late SessionManager session;
  late TraceManager trace;
  late DateTime now;
  late List<HttpHeaders> received;
  HttpOverrides? saved;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sink = _FakeSink();
    received = [];
    now = DateTime.utc(2026, 9, 29, 12);
    session = SessionManager(newSessionId: () => 'rotated');
    await session.startSession('session_1');
    trace = TraceManager(session: session, clock: () => now);
    resetHttpSeamState();
    // flutter_test installs its own overrides (a mock client for image
    // loading). Drop them, or every socket here is faked.
    saved = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDown(() {
    resetHttpSeamState();
    HttpOverrides.global = saved;
  });

  HttpCaptureHook startedHook({
    List<String> allowlist = const [],
    Uri? selfUrl,
  }) {
    final hook = HttpCaptureHook(
      injector: TraceInjector(trace: trace, allowlist: allowlist),
      selfUrl: selfUrl,
    );
    // The hook installs the global override on start; this seam is what is
    // under test, so take it straight back off.
    addTearDown(hook.start(sink));
    TelemetryHttpOverrides.uninstallGlobal();
    return hook;
  }

  Future<HttpServer> serve({Completer<void>? gate}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((req) async {
        received.add(req.headers);
        await req.drain<void>();
        if (gate != null) await gate.future;
        req.response.write('ok');
        await req.response.close();
      }),
    );
    addTearDown(() => server.close(force: true));
    return server;
  }

  Map<String, String> theRow() =>
      sink.events.singleWhere((e) => e.name == 'http.request').attributes;

  group('client in, same type out', () {
    test('an already-captured client is returned unchanged', () async {
      final hook = startedHook();
      final once = hook.capture(http.Client());
      addTearDown(once.close);

      // Identity, not equality: the second call must not build a second
      // wrapper, which is how double capture is designed out rather than
      // documented around.
      expect(hook.capture(once), same(once));
      expect(hook.capture(hook.capture(once)), same(once));
    });

    test('wrapping twice produces one capture', () async {
      final server = await serve();
      final hook = startedHook();
      final client = hook.capture(hook.capture(http.Client()));
      addTearDown(client.close);

      await client.read(Uri.parse('http://127.0.0.1:${server.port}/orders/42'));

      expect(sink.events.where((e) => e.name == 'http.request'), hasLength(1));
    });

    test('a pre-init call returns the consumer their own client', () {
      // A hook that was never started has no sink — nowhere to emit — and a
      // wrapper that silently dropped rows would be worse than none.
      final hook = HttpCaptureHook();
      final client = http.Client();
      addTearDown(client.close);
      expect(hook.capture(client), same(client));
    });

    test('a disposed hook stops capturing', () {
      final hook = HttpCaptureHook();
      hook.start(sink)();
      final client = http.Client();
      addTearDown(client.close);
      expect(hook.capture(client), same(client));
    });

    test('a client wrapped before dispose stops emitting after it', () async {
      final server = await serve();
      final hook = HttpCaptureHook(injector: TraceInjector(trace: trace));
      final dispose = hook.start(sink);
      TelemetryHttpOverrides.uninstallGlobal();
      final client = hook.capture(http.Client());
      addTearDown(client.close);

      dispose();
      await client.read(Uri.parse('http://127.0.0.1:${server.port}/x'));

      // The wrapper outlives the hook — it is the consumer's object now — but
      // it must not go on filling a pipeline nobody is draining.
      expect(sink.events, isEmpty);
      // And the seam state stops claiming the wrapper half.
      expect(httpSeamState(), kSeamStateBlind);
    });

    test('an IOClient is left alone while our own override is live', () {
      final hook = HttpCaptureHook(injector: TraceInjector(trace: trace));
      addTearDown(hook.start(sink));
      // The override the hook just installed is ours, and a plain
      // `http.Client()` is an `IOClient` whose sockets already pass it.
      // Wrapping would measure one request through two seams, so the decision
      // is made here rather than documented in the dartdoc.
      final client = http.Client();
      addTearDown(client.close);
      expect(hook.capture(client), same(client));
      expect(httpSeamState(), kSeamStateOverrides);
    });
  });

  group('the loopback seam', () {
    test('the event and the header agree, from one frozen copy', () async {
      final server = await serve();
      final hook = startedHook(allowlist: const ['127.0.0.1']);
      final client = hook.capture(http.Client());
      addTearDown(client.close);
      trace.mint(TraceRootType.interaction);

      await client.read(Uri.parse('http://127.0.0.1:${server.port}/orders/42'));

      final attrs = theRow();
      expect(attrs['traceparent.outcome'], kOutcomeInjectedAttributed);
      expect(
        received.single.value(kTraceparentHeader),
        formatTraceparent(attrs['trace.id']!, attrs['span.id']!),
      );
      expect(attrs['trace.root_type'], 'interaction');
      expect(attrs['parent.span.id'], attrs['rum.action.id']);
    });

    test('the row names this seam and claims no connection numbers', () async {
      final server = await serve();
      final hook = startedHook();
      final client = hook.capture(http.Client());
      addTearDown(client.close);

      await client.read(Uri.parse('http://127.0.0.1:${server.port}/orders/42'));

      final attrs = theRow();
      expect(attrs['http.seam'], kSeamHttpClient);
      // Structural: the platform client below this wrapper owns the connection
      // pool, so these are unreachable here — and omitted, never zeroed.
      expect(attrs.containsKey('http.connect_ms'), isFalse);
      expect(attrs.containsKey('http.connection_reused'), isFalse);
      // The id is templated and the query dropped, exactly as on the other
      // seam — the redaction lives in `toAttributes`, which both seams share.
      expect(attrs['http.url'], endsWith('/orders/{id}'));
      expect(attrs['http.success'], 'true');
      expect(attrs['http.status_code'], '200');
    });

    test('the outcome describes the frozen instant, not completion', () async {
      final gate = Completer<void>();
      final server = await serve(gate: gate);
      final hook = startedHook(allowlist: const ['127.0.0.1']);
      final client = hook.capture(http.Client());
      addTearDown(client.close);
      trace.mint(TraceRootType.interaction);

      final pending = client.read(
        Uri.parse('http://127.0.0.1:${server.port}/slow'),
      );
      // The root ages far past its 10 s cap while the response is in flight.
      now = now.add(const Duration(hours: 1));
      gate.complete();
      await pending;

      // Freeze and inject were one instant on this seam — `send` is entered
      // synchronously and the headers precede it — so nothing that happens
      // after can reach the decision. `injected_expired` is unreachable here.
      expect(theRow()['traceparent.outcome'], kOutcomeInjectedAttributed);
    });

    test('a request that never reaches a socket is still a row', () async {
      final hook = startedHook(allowlist: const ['127.0.0.1']);
      final client = hook.capture(http.Client());
      addTearDown(client.close);
      trace.mint(TraceRootType.interaction);

      // Port 1 on loopback refuses.
      await expectLater(
        client.read(Uri.parse('http://127.0.0.1:1/orders/42')),
        throwsA(anything),
      );

      final attrs = theRow();
      expect(attrs['http.status_code'], '0');
      expect(attrs['http.error'], isNotNull);
      expect(attrs['http.seam'], kSeamHttpClient);
      expect(attrs['trace.id'], isNotNull);
      // **The divergence from the `dart:io` seam, and why.** There the header
      // is written after the connection opens, so a refusal means it was never
      // written and the outcome is legitimately absent. Here it is written
      // before the send, unconditionally — `IOClient` finalizes the request
      // before it connects — so the outcome reports what the SDK did, which is
      // true on every path, instead of guessing what the socket did.
      expect(attrs['traceparent.outcome'], kOutcomeInjectedAttributed);
    });

    test('a socket that dies after the headers went out stays traced', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      // Accept, read the request — so the header provably left — then kill the
      // connection without answering.
      unawaited(
        server.forEach((req) async {
          received.add(req.headers);
          await req.drain<void>();
          await req.response.detachSocket().then((s) => s.destroy());
        }),
      );
      final hook = startedHook(allowlist: const ['127.0.0.1']);
      final client = hook.capture(http.Client());
      addTearDown(client.close);
      trace.mint(TraceRootType.interaction);

      await expectLater(
        client.read(Uri.parse('http://127.0.0.1:${server.port}/x')),
        throwsA(anything),
      );

      // The header *was* propagated — the server has it — so dropping the
      // outcome here would report "not traced" for a request the collector saw
      // traced. Only a request that never finalized loses the key.
      expect(received.single.value(kTraceparentHeader), isNotNull);
      expect(theRow()['traceparent.outcome'], kOutcomeInjectedAttributed);
    });

    test('the SDK\'s own upload is neither reported nor traced', () async {
      final server = await serve();
      final self = Uri.parse(
        'http://127.0.0.1:${server.port}/collector/telemetry',
      );
      final hook = startedHook(allowlist: const ['127.0.0.1'], selfUrl: self);
      final client = hook.capture(http.Client());
      addTearDown(client.close);
      trace.mint(TraceRootType.interaction);

      await client.post(self, body: 'payload');

      expect(sink.events.where((e) => e.name == 'http.request'), isEmpty);
      expect(received.single.value(kTraceparentHeader), isNull);
    });

    test('a consumer traceparent is adopted, never overwritten', () async {
      final server = await serve();
      final hook = startedHook(allowlist: const ['127.0.0.1']);
      final client = hook.capture(http.Client());
      addTearDown(client.close);
      final theirs = '00-${'a' * 32}-${'b' * 16}-01';

      await client.get(
        Uri.parse('http://127.0.0.1:${server.port}/x'),
        headers: {kTraceparentHeader: theirs},
      );

      expect(received.single.value(kTraceparentHeader), theirs);
      final attrs = theRow();
      expect(attrs['traceparent.outcome'], kOutcomeAdopted);
      expect(attrs['trace.id'], 'a' * 32);
    });
  });

  group('the seam state never claims coverage', () {
    test('blind is provable: no override of ours, nothing wrapped', () {
      expect(httpSeamState(), kSeamStateBlind);
    });

    test('overrides alone', () {
      TelemetryHttpOverrides.installGlobal(onRequestComplete: (_) {});
      addTearDown(TelemetryHttpOverrides.uninstallGlobal);
      expect(httpSeamState(), kSeamStateOverrides);
    });

    test('both, then blind again the instant a consumer severs the global', () {
      TelemetryHttpOverrides.installGlobal(onRequestComplete: (_) {});
      addTearDown(TelemetryHttpOverrides.uninstallGlobal);
      recordClientWrapped();
      expect(httpSeamState(), kSeamStateBoth);

      // The state nothing notifies us of. A value latched at install would go
      // on claiming a seam that has been dead for the rest of the session.
      HttpOverrides.global = null;
      expect(httpSeamState(), kSeamStateWrapper);
    });

    test('a started hook reports the wrapper half once it has wrapped one', () {
      final hook = startedHook();
      expect(httpSeamState(), kSeamStateBlind);
      addTearDown(hook.capture(http.Client()).close);
      expect(httpSeamState(), kSeamStateWrapper);
    });
  });
}

class _FakeSink implements EventSink {
  final List<EdgeEvent> events = [];
  @override
  void add(EdgeEvent event) => events.add(event);
}
