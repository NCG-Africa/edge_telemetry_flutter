// test/unit/crash/error_taxonomy_test.dart
//
// #90 (§11): the non-fatal error taxonomy and the rail move. Asserts what leaves
// the device — a build-method error loop produces capped *batched* items rather
// than N single-attempt POSTs, the ring carries 50 on a fatal and 10 on a
// non-fatal, and the taxonomy is inferred from exact types, never messages.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/capture/capture_hook.dart';
import 'package:edge_telemetry_flutter/src/capture/http_capture_hook.dart';
import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/crash/crash_reporting.dart';
import 'package:edge_telemetry_flutter/src/crash/error_category.dart';
import 'package:edge_telemetry_flutter/src/managers/breadcrumb_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];

  /// Wire items, unwrapped from their `telemetry_batch` envelope — both rails
  /// envelope since #81.
  List<Map<String, dynamic>> get items => [
        for (final p in sent)
          ...?(p['events'] as List?)?.cast<Map<String, dynamic>>()
      ];

  List<Map<String, dynamic>> named(String name) =>
      items.where((i) => i['eventName'] == name).toList();

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const reporting = CrashReporting();

  const idle = Duration(minutes: 30);
  late DateTime clock;
  setUp(() => clock = DateTime(2026, 1, 1, 9, 0, 0));

  /// Cross the idle timeout so the next event finalizes the open session — the
  /// bookend is the only place the dropped-item count ships.
  void rotate(SessionManager session) {
    clock = clock.add(idle + const Duration(minutes: 1));
    session.beforeEvent();
  }

  /// A real object graph with a huge batch size, so **only** the immediate rail
  /// can produce a POST on its own — a batched item shows up only once the
  /// Pipeline is flushed explicitly. That is what makes "batch rail" assertable
  /// rather than a spelling.
  Future<(Collector, SessionManager, Pipeline, _RecordingSender)> wire({
    BreadcrumbManager? breadcrumbs,
  }) async {
    final sender = _RecordingSender();
    var ids = 0;
    final session = SessionManager(
        newSessionId: () => 'session_${++ids}',
        clock: () => clock,
        idleTimeout: idle);
    final context =
        ContextManager(sessionManager: session, global: {'device.id': 'd_1'});
    final pipeline = Pipeline(
      transport: RetryTransport(
          endpoint: 'https://api.example.test',
          queue: _NoopQueue(),
          sender: sender.call),
      batchSize: 10000,
    );
    final collector = Collector(
        context: context,
        session: session,
        pipeline: pipeline,
        breadcrumbs: breadcrumbs);
    session.bindSink(collector);
    await session.recoverAndStart();
    return (collector, session, pipeline, sender);
  }

  group('error.category — inferred from exact platform types only', () {
    test('the whole inference table', () {
      expect(
          inferErrorCategory(TimeoutException('slow')), ErrorCategory.timeout);
      expect(inferErrorCategory(const SocketException('no route')),
          ErrorCategory.network);
      expect(inferErrorCategory(const HttpException('bad')),
          ErrorCategory.network);
      expect(inferErrorCategory(const FileSystemException('disk')),
          ErrorCategory.storage);
      expect(inferErrorCategory(const FormatException('json')),
          ErrorCategory.parse);
    });

    test('anything unlisted is unknown — inference never guesses', () {
      expect(inferErrorCategory(StateError('boom')), ErrorCategory.unknown);
      expect(inferErrorCategory(Exception('x')), ErrorCategory.unknown);
      expect(inferErrorCategory(ArgumentError('x')), ErrorCategory.unknown);
    });

    test('a message that names a category does not make one — no string match',
        () {
      // The exact defect the type table exists to prevent: an author rewording
      // this message in a patch release must not reclassify the error.
      for (final message in [
        'connection timed out',
        'auth failed: 401 unauthorized',
        'failed to parse response',
        'socket closed',
      ]) {
        expect(inferErrorCategory(StateError(message)), ErrorCategory.unknown,
            reason: message);
      }
    });

    test('auth and business are declared-only — no type infers them', () {
      const declaredOnly = {ErrorCategory.auth, ErrorCategory.business};
      for (final error in <Object>[
        TimeoutException('t'),
        const SocketException('s'),
        const HttpException('h'),
        const FileSystemException('f'),
        const FormatException('p'),
        StateError('s'),
        Exception('e'),
      ]) {
        expect(declaredOnly.contains(inferErrorCategory(error)), isFalse);
      }
    });

    test('the event carries the category plus its source flag', () {
      final inferred =
          reporting.buildCrashEvent(const SocketException('no route'));
      expect(inferred.attributes['error.category'], 'network');
      expect(inferred.attributes['error.category_source'], 'inferred');

      // Declared wins over what the type would have inferred — the consumer
      // knows things the type does not.
      final declared = reporting.buildCrashEvent(const HttpException('401'),
          category: ErrorCategory.auth);
      expect(declared.attributes['error.category'], 'auth');
      expect(declared.attributes['error.category_source'], 'declared');
    });

    test('the taxonomy is a new key — cause is untouched', () {
      final a = reporting
          .buildCrashEvent(const SocketException('x'),
              category: ErrorCategory.business)
          .attributes;
      expect(a['cause'], 'Error'); // shipped enum, never the taxonomy
      expect(a['error.category'], 'business');
    });

    test('every wire value is the enum name, spelled out', () {
      expect([
        for (final c in ErrorCategory.values) c.wire
      ], [
        'network',
        'timeout',
        'auth',
        'parse',
        'storage',
        'business',
        'unknown',
      ]);
    });
  });

  group('handled — spelled as a string, matching is_fatal', () {
    test('the three auto handlers are unhandled; trackError is handled', () {
      for (final source in [
        'flutter_error',
        'platform_dispatcher',
        'isolate',
      ]) {
        expect(
            reporting
                .buildCrashEvent(Exception('x'), source: source)
                .attributes['handled'],
            'false',
            reason: source);
      }
      // Host trackError: no source token, a live catch.
      expect(reporting.buildCrashEvent(Exception('x')).attributes['handled'],
          'true');
    });

    test('a native crash is unhandled without a channel-contract change', () {
      final a = reporting.buildNativeCrashEvent({
        'message': 'SIGSEGV',
        'cause': 'NativeCrash',
        'is_fatal': 'true',
      }).attributes;
      expect(a['handled'], 'false');
      expect(a['is_fatal'], 'true'); // same string spelling, not a bool
      // The facet covers the fatal half; nothing was inferred or declared, so
      // the source flag is absent rather than claiming a guess.
      expect(a['error.category'], 'unknown');
      expect(a.containsKey('error.category_source'), isFalse);
    });
  });

  group('rails — fatal immediate, non-fatal batched, bypass kept on both', () {
    test('a non-fatal does not POST on its own; a flush carries it', () async {
      final (collector, _, pipeline, sender) = await wire();

      collector.add(reporting.buildCrashEvent(StateError('boom'),
          source: 'flutter_error'));
      await Future<void>(() {});

      // The bookend rode the immediate rail; the error did not.
      expect(sender.named('app.crash'), isEmpty);

      pipeline.flush();
      await Future<void>(() {});
      expect(sender.named('app.crash'), hasLength(1));
    });

    test('a fatal still POSTs immediately — its process is dying', () async {
      final (collector, _, _, sender) = await wire();

      collector.add(reporting.buildNativeCrashEvent({
        'message': 'SIGSEGV',
        'cause': 'NativeCrash',
        'is_fatal': 'true',
        'crash.source': 'metrickit',
      }));
      await Future<void>(() {});

      expect(sender.named('app.crash'), hasLength(1));
    });

    test(
        'rail and sampling are orthogonal: a sampled-out session still '
        'reports its non-fatals', () async {
      final sender = _RecordingSender();
      final session = SessionManager(
          newSessionId: () => 'session_test',
          clock: () => clock,
          sampledRoll: () => false);
      final context = ContextManager(sessionManager: session);
      final pipeline = Pipeline(
        transport: RetryTransport(
            endpoint: 'https://api.example.test',
            queue: _NoopQueue(),
            sender: sender.call),
        batchSize: 10000,
      );
      final collector =
          Collector(context: context, session: session, pipeline: pipeline);
      session.bindSink(collector);
      await session.recoverAndStart();

      // Sampled out: an ordinary event never reaches the wire.
      collector.add(const EdgeEvent.event('custom_event'));
      collector.add(reporting.buildCrashEvent(StateError('boom')));
      pipeline.flush();
      await Future<void>(() {});

      expect(sender.named('custom_event'), isEmpty);
      expect(sender.named('app.crash'), hasLength(1));
    });
  });

  group('per-session caps — the build-method flood', () {
    test('one error thrown 40× ships 5 items, not 40 POSTs', () async {
      final (collector, session, pipeline, sender) = await wire();

      // One fault, one call site: the same exception type and the same top
      // frame every time — exactly what a failing build() produces.
      final stack = StackTrace.fromString(
          '#0 _MyWidgetState.build (package:app/my_widget.dart:42:7)\n'
          '#1 StatefulElement.build (package:flutter/src/widgets/framework.dart)');
      for (var i = 0; i < 40; i++) {
        collector.add(reporting.buildCrashEvent(StateError('boom'),
            stackTrace: stack, source: 'flutter_error'));
      }
      pipeline.flush();
      await Future<void>(() {});

      expect(sender.named('app.crash'), hasLength(kErrorPerKeyCap));
      // One POST for the batch (the bookend's own is a separate payload).
      expect(sender.sent.where((p) => (p['events'] as List).length > 1),
          hasLength(1));

      // And the overflow is visible rather than silent.
      rotate(session);
      await Future<void>(() {});
      final finalize = sender.named('session.finalized').last;
      final attrs = (finalize['attributes'] as Map).cast<String, String>();
      expect(attrs['session.dropped_item_count'], '35');
      expect(attrs['session.dropped_reasons'], contains('error_cap'));
      // The counter counts what happened, not what shipped — same rule as
      // `session.action_count`. 5 sent + 35 dropped adds back to 40.
      expect(attrs['session.error_count'], '40');
    });

    test('the dedup key is type + top frame — a different frame is a new key',
        () async {
      final (collector, _, pipeline, sender) = await wire();

      for (var call = 0; call < 3; call++) {
        for (var i = 0; i < 8; i++) {
          collector.add(reporting.buildCrashEvent(StateError('boom'),
              stackTrace:
                  StackTrace.fromString('#0 siteNumber$call (file.dart:$call)'),
              source: 'flutter_error'));
        }
      }
      pipeline.flush();
      await Future<void>(() {});

      // Three distinct faults, five each — not five in total.
      expect(sender.named('app.crash'), hasLength(3 * kErrorPerKeyCap));
    });

    test('the overall cap bounds a session that keeps minting new keys',
        () async {
      final (collector, _, pipeline, sender) = await wire();

      for (var i = 0; i < 80; i++) {
        collector.add(reporting.buildCrashEvent(StateError('boom'),
            stackTrace: StackTrace.fromString('#0 site$i (file.dart:$i)'),
            source: 'flutter_error'));
      }
      pipeline.flush();
      await Future<void>(() {});

      expect(sender.named('app.crash'), hasLength(kErrorSessionCap));
    });

    test('a consumer attribute cannot route a non-fatal onto the fatal rail',
        () async {
      final (collector, _, pipeline, sender) = await wire();

      // `is_fatal` selects the rail now, so the SDK's value has to win.
      collector.add(reporting.buildCrashEvent(StateError('boom'),
          attributes: {'is_fatal': 'true', 'handled': 'false'}));
      await Future<void>(() {});

      // Nothing POSTed on its own — only the session.started bookend is out.
      expect(sender.named('app.crash'), isEmpty);

      pipeline.flush();
      await Future<void>(() {});

      final a = sender.named('app.crash').single['attributes'] as Map;
      expect(a['is_fatal'], 'false'); // the SDK's value, not the consumer's
      expect(a['handled'], 'true');
    });

    test('a fatal is exempt from both caps', () async {
      final (collector, _, _, sender) = await wire();

      for (var i = 0; i < 60; i++) {
        collector.add(reporting.buildNativeCrashEvent({
          'message': 'SIGSEGV',
          'cause': 'NativeCrash',
          'is_fatal': 'true',
        }));
      }
      await Future<void>(() {});
      expect(sender.named('app.crash'), hasLength(60));
    });

    test('the allowance is per session — rotation refills it', () async {
      final (collector, _, pipeline, sender) = await wire();
      final stack = StackTrace.fromString('#0 build (file.dart:1)');

      void flood() {
        for (var i = 0; i < 10; i++) {
          collector.add(reporting.buildCrashEvent(StateError('boom'),
              stackTrace: stack, source: 'flutter_error'));
        }
      }

      flood();
      collector.resetPerSessionCaps();
      flood();
      pipeline.flush();
      await Future<void>(() {});

      expect(sender.named('app.crash'), hasLength(2 * kErrorPerKeyCap));
    });
  });

  group('breadcrumbs — ring 50, fatal ships all, non-fatal ships 10', () {
    test('the ring holds 50', () {
      final ring = BreadcrumbManager();
      for (var i = 0; i < 80; i++) {
        ring.addCustom('crumb_$i');
      }
      expect(ring.count, 50);
      expect(ring.maxBreadcrumbs, 50);
      // Newest first, oldest evicted.
      expect(ring.getBreadcrumbs().first.message, 'crumb_79');
      expect(ring.getBreadcrumbs().last.message, 'crumb_30');
    });

    List<dynamic> crumbsOnWire(Map<String, dynamic> item) =>
        jsonDecode((item['attributes'] as Map)['crash.breadcrumbs'] as String)
            as List;

    test('a fatal carries all 50; a non-fatal the newest 10', () async {
      final ring = BreadcrumbManager();
      for (var i = 0; i < 60; i++) {
        ring.addCustom('crumb_$i');
      }
      final (collector, _, pipeline, sender) = await wire(breadcrumbs: ring);

      collector.add(reporting.buildNativeCrashEvent({
        'message': 'SIGSEGV',
        'cause': 'NativeCrash',
        'is_fatal': 'true',
      }));
      collector.add(reporting.buildCrashEvent(StateError('boom'),
          source: 'flutter_error'));
      pipeline.flush();
      await Future<void>(() {});

      final crashes = sender.named('app.crash');
      final fatal = crashes
          .firstWhere((c) => (c['attributes'] as Map)['is_fatal'] == 'true');
      final nonFatal = crashes
          .firstWhere((c) => (c['attributes'] as Map)['is_fatal'] == 'false');

      expect(crumbsOnWire(fatal), hasLength(50));
      expect(crumbsOnWire(nonFatal), hasLength(10));
      // Newest ten, not the oldest ten.
      expect((crumbsOnWire(nonFatal).first as Map)['message'], 'crumb_59');
    });

    test('an empty ring omits the key rather than sending "[]"', () async {
      final (collector, _, pipeline, sender) =
          await wire(breadcrumbs: BreadcrumbManager());
      collector.add(reporting.buildCrashEvent(StateError('boom')));
      pipeline.flush();
      await Future<void>(() {});

      final attrs = sender.named('app.crash').single['attributes'] as Map;
      expect(attrs.containsKey('crash.breadcrumbs'), isFalse);
    });
  });

  group('attribution and absences', () {
    test('unprefixed spelling survives the taxonomy addition', () async {
      final a = reporting
          .buildCrashEvent(StateError('boom'),
              stackTrace: StackTrace.fromString('#0 main'),
              source: 'flutter_error')
          .attributes;
      // The backend extractors read these verbatim — a dotted taxonomy key
      // beside them must not have renamed any of them.
      expect(a['message'], 'Bad state: boom');
      expect(a['stacktrace'], '#0 main');
      expect(a['exception_type'], 'StateError');
      expect(a['cause'], 'Error');
      expect(a['is_fatal'], 'false');
    });

    test('no error id and no client-side fingerprint', () {
      final a = reporting
          .buildCrashEvent(StateError('boom'),
              stackTrace: StackTrace.fromString('#0 main'))
          .attributes;
      for (final absent in [
        'error_id',
        'error.id',
        'crash_hash',
        'crash.fingerprint',
        'error.fingerprint',
        'severity',
      ]) {
        expect(a.containsKey(absent), isFalse, reason: absent);
      }
    });

    test('an SDK-internal failure is tagged and stays off the host error rate',
        () async {
      final (collector, session, pipeline, sender) = await wire();

      collector.add(EdgeEvent.error(const SocketException('sdk socket'),
          source: kSdkCrashSource,
          attributes: {'error.component': 'flutter_network_monitor'}));
      pipeline.flush();
      await Future<void>(() {});

      final attrs = sender.named('app.crash').single['attributes']
          as Map<String, dynamic>;
      expect(attrs['crash.source'], 'sdk');
      // Exempt from inference: a SocketException inside the SDK is not the host
      // app's network problem — and the source flag is omitted rather than
      // claiming an inference that never ran.
      expect(attrs['error.category'], 'unknown');
      expect(attrs.containsKey('error.category_source'), isFalse);

      rotate(session);
      await Future<void>(() {});
      final finalize =
          (sender.named('session.finalized').last['attributes'] as Map)
              .cast<String, String>();
      expect(finalize['session.error_count'], '0');
      expect(finalize['session.crash_count'], '0');
    });

    test('a host error does count on the bookend', () async {
      final (collector, session, pipeline, sender) = await wire();

      collector.add(reporting.buildCrashEvent(StateError('boom'),
          source: 'flutter_error'));
      pipeline.flush();
      rotate(session);
      await Future<void>(() {});

      final finalize =
          (sender.named('session.finalized').last['attributes'] as Map)
              .cast<String, String>();
      expect(finalize['session.error_count'], '1');
      expect(finalize['session.crash_count'], '1');
    });
  });

  group('HTTP failures emit no crash event', () {
    late _FakeSink sink;
    HttpOverrides? saved;
    late DisposeHandle dispose;

    setUp(() {
      sink = _FakeSink();
      // flutter_test installs its own overrides (a mock client for image
      // loading). Drop them, or the socket below is faked.
      saved = HttpOverrides.current;
      HttpOverrides.global = null;
      dispose = HttpCaptureHook().start(sink);
    });

    tearDown(() {
      dispose();
      HttpOverrides.global = saved;
    });

    test('a refused connection is one http.request, not an app.crash',
        () async {
      // A port nothing listens on: the request fails at connect, which is the
      // path that would have double-counted as both a request row and a crash.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      await expectLater(
          HttpClient().getUrl(Uri.parse('http://127.0.0.1:$port/fail')),
          throwsA(isA<SocketException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sink.events.map((e) => e.name), ['http.request']);
      // The failure is a queryable attribute on the request row — status code
      // and error text — so auth-vs-server is a query, never a second item.
      final a = sink.events.single.attributes;
      expect(a.containsKey('http.error'), isTrue);
      expect(a['http.success'], 'false');
    });
  });
}

class _FakeSink implements EventSink {
  final List<EdgeEvent> events = [];
  @override
  void add(EdgeEvent event) => events.add(event);
}
