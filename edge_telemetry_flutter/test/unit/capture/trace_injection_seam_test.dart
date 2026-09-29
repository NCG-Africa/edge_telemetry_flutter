// test/unit/capture/trace_injection_seam_test.dart
//
// The new seam §5 asks for (#86): a real loopback HTTP server behind the real
// `dart:io` wrapper. It is the **only** place the injected header and the event
// describing that request are observable together, and their agreement is the
// load-bearing consequence of the freeze rule — a stub would stub exactly the
// platform internals the riskiest decisions depend on.

import 'dart:async';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/capture/http_overrides.dart';
import 'package:edge_telemetry_flutter/src/capture/trace_injection.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/trace_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('allowlist matching — the sibling rule verbatim', () {
    test('an empty allowlist is dark', () {
      expect(hostAllowed('api.example.com', const []), isFalse);
    });

    test('exact host', () {
      expect(hostAllowed('api.example.com', const ['api.example.com']), isTrue);
      expect(
          hostAllowed('other.example.com', const ['api.example.com']), isFalse);
    });

    test('a dot-anchored suffix matches a subdomain, not a lookalike', () {
      const list = ['.example.com'];
      expect(hostAllowed('api.example.com', list), isTrue);
      expect(hostAllowed('a.b.example.com', list), isTrue);
      // The whole point of the anchor: this is a *different* registrable domain
      // that merely contains the allowed one.
      expect(hostAllowed('api.example.com.evil.com', list), isFalse);
      // The bare apex is not a subdomain of itself under the anchor.
      expect(hostAllowed('example.com', list), isFalse);
    });

    test('a one-label anchor matches nothing', () {
      expect(hostAllowed('api.example.com', const ['.com']), isFalse);
    });

    test('matching is case-insensitive', () {
      expect(hostAllowed('API.Example.COM', const ['.example.com']), isTrue);
    });
  });

  group('traceparent format', () {
    test('version 00, flags literally 01 — one sampling decision', () {
      final header = formatTraceparent('a' * 32, 'b' * 16);
      expect(header, '00-${'a' * 32}-${'b' * 16}-01');
      // The set flag *is* the decision: there is no trace sampling rate, so
      // "traced but unsampled" — whose whole mechanism is the unset flag —
      // is unrepresentable by construction.
      expect(header.endsWith('-01'), isTrue);
    });

    test('a malformed inbound header is overwritten, never passed through', () {
      // Uppercase, short, all-zero and absent all read as "no inbound trace".
      // The processor truncates without validating and `edge_db` then fails the
      // insert, so adopting a bad id would delete the row.
      expect(parseTraceparent(null), isNull);
      expect(parseTraceparent('00-${'A' * 32}-${'b' * 16}-01'), isNull);
      expect(parseTraceparent('00-${'a' * 31}-${'b' * 16}-01'), isNull);
      expect(parseTraceparent('00-${'0' * 32}-${'b' * 16}-01'), isNull);
      expect(parseTraceparent('00-${'a' * 32}-${'0' * 16}-01'), isNull);
      expect(parseTraceparent('01-${'a' * 32}-${'b' * 16}-01'), isNull);
    });

    test('a valid inbound header parses to its two ids', () {
      final got = parseTraceparent('00-${'a' * 32}-${'b' * 16}-00');
      expect(got?.traceId, 'a' * 32);
      expect(got?.spanId, 'b' * 16);
    });
  });

  group('the loopback seam', () {
    late List<HttpRequestTelemetry> records;
    late List<HttpHeaders> received;
    late SessionManager session;
    late TraceManager trace;
    HttpOverrides? saved;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      records = [];
      received = [];
      var rotations = 0;
      session = SessionManager(newSessionId: () => 'rotated_${++rotations}');
      await session.startSession('session_1');
      trace = TraceManager(session: session);
      // flutter_test installs its own overrides (a mock client for image
      // loading). Drop them, or every socket here is faked.
      saved = HttpOverrides.current;
      HttpOverrides.global = null;
    });

    tearDown(() {
      TelemetryHttpOverrides.uninstallGlobal();
      HttpOverrides.global = saved;
    });

    void install({List<String> allowlist = const [], Uri? selfUrl}) {
      TelemetryHttpOverrides.installGlobal(
        onRequestComplete: records.add,
        injector: TraceInjector(trace: trace, allowlist: allowlist),
        selfUrl: selfUrl,
      );
    }

    Future<HttpServer> serve({Uri? redirectTo}) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(server.forEach((req) async {
        received.add(req.headers);
        await req.drain<void>();
        final res = req.response;
        if (redirectTo != null) {
          res.statusCode = HttpStatus.movedTemporarily;
          res.headers.set(HttpHeaders.locationHeader, redirectTo.toString());
        } else {
          res.write('ok');
        }
        await res.close();
      }));
      return server;
    }

    Future<void> fetch(Uri url,
        {void Function(HttpClientRequest)? before}) async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(url);
      before?.call(request);
      final response = await request.close();
      await response.drain<void>();
    }

    String? header(int i) => received[i].value(kTraceparentHeader);

    test('the header and the event agree, because they share one frozen copy',
        () async {
      final server = await serve();
      addTearDown(() => server.close(force: true));
      install(allowlist: const ['127.0.0.1']);
      trace.mint(TraceRootType.interaction);

      await fetch(Uri.parse('http://127.0.0.1:${server.port}/orders/42'));

      final attrs = records.single.toAttributes();
      expect(attrs['traceparent.outcome'], kOutcomeInjectedAttributed);
      // The whole ticket in one assertion: what left on the wire is what the
      // row describing it says left.
      expect(
          header(0), formatTraceparent(attrs['trace.id']!, attrs['span.id']!));
      // Root type is denormalised onto the child, so "are launch requests
      // slower" is a single-table scan.
      expect(attrs['trace.root_type'], 'interaction');
      expect(attrs['parent.span.id'], attrs['rum.action.id']);
      expect(attrs['span.start_time'], endsWith('Z'));
      expect(int.parse(attrs['span.duration_ms']!), greaterThanOrEqualTo(0));
    });

    test('an off-allowlist host is stamped locally and sent no header',
        () async {
      final server = await serve();
      addTearDown(() => server.close(force: true));
      install(); // dark by default
      trace.mint(TraceRootType.interaction);

      await fetch(Uri.parse('http://127.0.0.1:${server.port}/orders/42'));

      final attrs = records.single.toAttributes();
      expect(attrs['traceparent.outcome'], kOutcomeSkippedOffAllowlist);
      expect(header(0), isNull);
      // Still correlatable inside the session — only propagation is withheld.
      expect(attrs['trace.id'], isNotNull);
      expect(attrs['span.id'], isNotNull);
    });

    test('nothing ambient at the freeze instant re-roots parentless', () async {
      final server = await serve();
      addTearDown(() => server.close(force: true));
      install(allowlist: const ['127.0.0.1']);
      // No root minted.

      await fetch(Uri.parse('http://127.0.0.1:${server.port}/ping'));

      final attrs = records.single.toAttributes();
      expect(attrs['traceparent.outcome'], kOutcomeInjectedUnattributed);
      expect(attrs['trace.root_type'], 'request');
      // A root is its own action, and `parent.span.id` is children-only.
      expect(attrs.containsKey('parent.span.id'), isFalse);
      expect(attrs['rum.action.id'], attrs['span.id']);
      expect(
          header(0), formatTraceparent(attrs['trace.id']!, attrs['span.id']!));
    });

    test('a session rotation under an in-flight request discards and re-roots',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        received.add(req.headers);
        await req.drain<void>();
        await (req.response..write('ok')).close();
      }));
      install(allowlist: const ['127.0.0.1']);
      trace.mint(TraceRootType.interaction);
      final frozenTraceId = trace.current()['trace.id'];

      // Rotate between the freeze (openUrl entry) and the inject (close) — the
      // half that actually bites, since it is the requests in flight when the
      // app came back that matter most.
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/x'));
      await session.startSession('session_2');
      final response = await request.close();
      await response.drain<void>();

      final attrs = records.single.toAttributes();
      expect(attrs['traceparent.outcome'], kOutcomeInjectedExpired);
      expect(attrs['trace.id'], isNot(frozenTraceId));
      expect(attrs['trace.root_type'], 'request');
      expect(
          header(0), formatTraceparent(attrs['trace.id']!, attrs['span.id']!));
    });

    test("the host app's own traceparent is adopted, not overwritten",
        () async {
      final server = await serve();
      addTearDown(() => server.close(force: true));
      install(allowlist: const ['127.0.0.1']);
      trace.mint(TraceRootType.interaction);
      final localAction = trace.current()['rum.action.id'];
      final theirs = formatTraceparent('c' * 32, 'd' * 16);

      await fetch(
        Uri.parse('http://127.0.0.1:${server.port}/x'),
        before: (r) => r.headers.set(kTraceparentHeader, theirs),
      );

      final attrs = records.single.toAttributes();
      expect(attrs['traceparent.outcome'], kOutcomeAdopted);
      expect(header(0), theirs, reason: 'their header is left untouched');
      expect(attrs['trace.id'], 'c' * 32);
      expect(attrs['span.id'], 'd' * 16);
      expect(attrs.containsKey('parent.span.id'), isFalse,
          reason: 'root-shaped inside their trace');
      // Two keys doing two jobs: trace.id is their call chain, rum.action.id
      // is still our tap.
      expect(attrs['rum.action.id'], localAction);
    });

    test('the SDK\'s own upload emits nothing and carries no header', () async {
      final server = await serve();
      addTearDown(() => server.close(force: true));
      final self =
          Uri.parse('http://127.0.0.1:${server.port}/collector/telemetry');
      install(allowlist: const ['127.0.0.1'], selfUrl: self);
      trace.mint(TraceRootType.interaction);

      await fetch(self);

      // No event — the amplification loop is cut at the source — and no
      // outcome key anywhere, because absence is the contract's "not traced".
      expect(records, isEmpty);
      expect(header(0), isNull);
    });

    test('two requests over one connection get distinct spans, one reuse flag',
        () async {
      final server = await serve();
      addTearDown(() => server.close(force: true));
      install(allowlist: const ['127.0.0.1']);
      trace.mint(TraceRootType.interaction);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/x');
      for (var i = 0; i < 2; i++) {
        final response = await (await client.getUrl(url)).close();
        await response.drain<void>();
      }

      final first = records[0].toAttributes();
      final second = records[1].toAttributes();
      expect(first['trace.id'], second['trace.id'], reason: 'one root');
      expect(first['span.id'], isNot(second['span.id']));
      expect(header(0), isNot(header(1)));
      // Measured off the local-port join, not inferred from a fast connect.
      expect(records[0].connectionReused, isFalse);
      expect(records[1].connectionReused, isTrue);
    });

    test('KNOWN LIMITATION: a redirect carries the header off the allowlist',
        () async {
      // Declined, not tolerated. `followRedirects` defaults true and dart:io
      // copies headers onto the redirect target *inside* `close()`, below this
      // wrapper. Closing it means setting `followRedirects = false` internally
      // and re-driving each hop — the SDK seizing redirect semantics it does
      // not own, and changing the host app's HTTP behaviour, to fix a telemetry
      // concern. Asserted here so it stays a known, measured limitation rather
      // than a surprise; delete this test the day the decision is reversed.
      final target = await serve();
      addTearDown(() => target.close(force: true));
      // Same loopback address, a different host *string* — so it is off the
      // allowlist by the rule, exactly as a third-party domain would be.
      final redirector = await serve(
          redirectTo: Uri.parse('http://localhost:${target.port}/leaked'));
      addTearDown(() => redirector.close(force: true));
      install(allowlist: const ['127.0.0.1']);
      trace.mint(TraceRootType.interaction);

      await fetch(Uri.parse('http://127.0.0.1:${redirector.port}/go'));

      expect(header(0), isNotNull, reason: 'the allowlisted hop');
      expect(header(1), header(0),
          reason: 'the platform copied it onto the off-allowlist hop');
    });
  });
}
