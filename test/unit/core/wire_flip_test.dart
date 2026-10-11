// test/unit/core/wire_flip_test.dart
//
// The Phase-3 wire flip (#21): the assembled batch must match the family canon.
// Drives real EdgeEvents through Collector → Pipeline → transport and snapshots
// the envelope, allowlist filtering, http folding, metric renames, device.id
// presence, and the geo/tenant strip.

import 'dart:convert';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/core/collector.dart';
import 'package:edge_telemetry_flutter/src/core/edge_event.dart';
import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:edge_telemetry_flutter/src/core/sdk_version.dart';
import 'package:edge_telemetry_flutter/src/core/wire_canon.dart';
import 'package:edge_telemetry_flutter/src/managers/context_manager.dart';
import 'package:edge_telemetry_flutter/src/managers/session_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_identity.dart';

class _RecordingSender {
  final List<Map<String, dynamic>> sent = [];
  Future<bool> call(Map<String, dynamic> payload) async {
    sent.add(payload);
    return true;
  }
}

class _NoopQueue extends OfflineQueue {
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> persist(
    Map<String, dynamic> p, {
    bool isCrash = false,
  }) async => null;
  @override
  Future<int> drain(
    Future<DrainResult> Function(Map<String, dynamic>) s,
  ) async => 0;
}

/// Build a Collector wired to a recording sender; [flushAt] events per batch.
Future<(Collector, _RecordingSender)> _wire({
  int flushAt = 100,
  Map<String, String>? global,
  String endpoint = 'https://api.example.test',
  String? apiKey,
  bool realHttp = false,
}) async {
  final sender = _RecordingSender();
  final session = SessionManager();
  await session.startSession('session_test');
  final context = ContextManager(
    sessionManager: session,
    global: global ?? {'device.id': 'device_abc', 'user.id': 'user_abc'},
  );
  final transport = RetryTransport(
    endpoint: endpoint,
    apiKey: apiKey,
    queue: _NoopQueue(),
    sender: realHttp ? null : sender.call,
  );
  final pipeline = Pipeline(
    transport: transport,
    identity: kTestIdentity,
    batchSize: flushAt,
  );
  final collector = Collector(
    context: context,
    session: session,
    pipeline: pipeline,
  );
  return (collector, sender);
}

/// Normalize an assembled batch for golden comparison: blank the volatile
/// timestamps and drop the session.*/network.* attrs (owned by #9) plus the
/// live device-context keys (`device.platform_brightness` — owned by #26), none
/// of which the wire-flip canon (#21) this fixture pins is concerned with.
Map<String, dynamic> _normalize(Map<String, dynamic> batch) => {
  ...batch,
  'timestamp': '<TS>',
  'sdk': {...batch['sdk'] as Map, 'version': '<SDK>'},
  'events':
      (batch['events'] as List).map((e) {
        final ev = Map<String, dynamic>.from(e as Map);
        ev['timestamp'] = '<TS>';
        ev['attributes'] =
            Map<String, dynamic>.from(ev['attributes'] as Map)
              ..removeWhere(
                (k, _) =>
                    k.startsWith('session.') ||
                    k.startsWith('network.') ||
                    k == 'device.platform_brightness' ||
                    k == 'device.text_scale_factor' ||
                    k == 'device.reduce_motion',
              )
              // The key is canon and rides every item; its *value* says which
              // seams happen to be live in this process, so the fixture pins the
              // presence and not the environment.
              ..update(
                'http_seam_state',
                (_) => '<SEAM>',
                ifAbsent: () => '<MISSING>',
              );
        return ev;
      }).toList(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'batch envelope matches canon: telemetry_batch + fields + device.id',
    () async {
      final (collector, sender) = await _wire(flushAt: 2);

      collector.add(
        const EdgeEvent.event(
          'navigation',
          attributes: {'navigation.to': '/home'},
        ),
      );
      collector.add(const EdgeEvent.metric('frame_render_time', 12.5));
      await Future<void>(() {});

      expect(sender.sent, hasLength(1));
      final batch = sender.sent.single;
      // Exactly the R3 eight, in canon order.
      expect(batch.keys.toList(), kR3EnvelopeKeys);
      expect(batch['type'], 'telemetry_batch');
      expect(batch['contract_version'], '4.0.0');
      expect(batch['batch_size'], 2);
      expect(batch['device_id'], kTestIdentity.deviceId);
      expect(batch['sdk'], {'name': 'flutter', 'version': kSdkVersion});
      expect(batch['app'], kTestIdentity.app);

      final events = (batch['events'] as List).cast<Map<String, dynamic>>();
      expect(events.map((e) => e['eventName'] ?? e['metricName']), [
        'navigation',
        'frame_render_time',
      ]);
      // Identity rides the envelope only (R1): no per-item copy.
      for (final e in events) {
        expect((e['attributes'] as Map).containsKey('device.id'), isFalse);
      }
      // The metric keeps metricName + value at root (shape unchanged).
      expect(events[1]['metricName'], 'frame_render_time');
      expect(events[1]['value'], 12.5);
    },
  );

  test(
    'items carry no device.id, app.* or sdk.* — whoever set them (R1)',
    () async {
      final (collector, sender) = await _wire(
        flushAt: 1,
        global: {
          'device.id': 'device_abc',
          'device.model': 'Pixel 9',
          'device.platform': 'android',
          'app.version': '9.9.9', // a consumer global must not reach the wire
          'app.name': 'X',
          'sdk.version': '0.0.1',
          'user.id': 'user_abc',
        },
      );
      collector.add(
        const EdgeEvent.event(
          'custom_event',
          attributes: {'app.environment': 'prod', 'sdk.health': 'x'},
        ),
      );
      collector.add(const EdgeEvent.session('session.started', {}));
      await Future<void>(() {});

      final batches = sender.sent;
      expect(batches, hasLength(2)); // immediate + batched rails
      for (final batch in batches) {
        expect(batch['app'], kTestIdentity.app); // envelope wins
        for (final e in batch['events'] as List) {
          final attrs = (e as Map)['attributes'] as Map<String, dynamic>;
          expect(
            attrs.keys.where(
              (k) =>
                  k == 'device.id' ||
                  k.startsWith('app.') ||
                  k.startsWith('sdk.'),
            ),
            isEmpty,
          );
          // Other device.* keys stay per item.
          expect(attrs['device.model'], 'Pixel 9');
          expect(attrs['device.platform'], 'android');
          // The seam state moves into the item without its sdk. prefix.
          expect(attrs['http_seam_state'], isNotNull);
        }
      }
    },
  );

  test('envelope timestamp is UTC RFC 3339 with a Z (R13)', () async {
    final (collector, sender) = await _wire(flushAt: 1);
    collector.add(const EdgeEvent.event('navigation'));
    await Future<void>(() {});

    final ts = sender.sent.single['timestamp'] as String;
    expect(ts, endsWith('Z'));
    expect(DateTime.parse(ts).isUtc, isTrue);
    expect(
      DateTime.parse(ts).difference(DateTime.now().toUtc()).abs(),
      lessThan(const Duration(seconds: 5)),
    );
  });

  test('the immediate rail sends the same 4.0 envelope', () async {
    final (collector, sender) = await _wire();
    collector.add(const EdgeEvent.session('session.started', {}));
    await Future<void>(() {});

    final batch = sender.sent.single;
    expect(batch['contract_version'], '4.0.0');
    expect(batch['device_id'], kTestIdentity.deviceId);
    expect(batch['app'], kTestIdentity.app);
    expect(batch['batch_size'], 1);
  });

  test('app block: empty version, build_number or name is omitted (R15)', () {
    expect(
      appIdentity(
        name: '',
        packageName: 'com.x',
        platform: 'ios',
        version: '',
        buildNumber: null,
      ),
      {'package_name': 'com.x', 'platform': 'ios'},
    );
    // The other two of R15's four cases: a null version, an empty build.
    expect(
      appIdentity(
        packageName: 'com.x',
        platform: 'ios',
        version: null,
        buildNumber: '',
      ),
      {'package_name': 'com.x', 'platform': 'ios'},
    );
    expect(
      appIdentity(
        name: 'X',
        packageName: 'com.x',
        platform: 'android',
        version: '1.2',
        buildNumber: '7',
      ).keys.toList(),
      ['name', 'package_name', 'platform', 'version', 'build_number'],
    );
  });

  test('no clock_skew_ms and no context block, even after a POST whose Date '
      'header is 30s ahead (R5, R6)', () async {
    // The test binding answers every real HttpClient with a 400; this test
    // needs the socket.
    final bindingOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = bindingOverrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Map<String, dynamic>>[];
    server.listen((req) async {
      final raw = await req.fold<List<int>>([], (a, c) => a..addAll(c));
      final plain =
          req.headers.value('Content-Encoding') == 'gzip'
              ? gzip.decode(raw)
              : raw;
      bodies.add(jsonDecode(utf8.decode(plain)) as Map<String, dynamic>);
      req.response.headers.date = DateTime.now().add(
        const Duration(seconds: 30),
      );
      await req.response.close();
    });

    final (collector, _) = await _wire(
      flushAt: 1,
      endpoint: 'http://${server.address.host}:${server.port}',
      realHttp: true,
    );
    // Two sends: the second follows a successful POST whose Date header a
    // skew estimate would have been taken from.
    collector.add(const EdgeEvent.event('navigation'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    collector.add(const EdgeEvent.event('navigation'));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(bodies, hasLength(2));
    for (final b in bodies) {
      expect(b.containsKey('clock_skew_ms'), isFalse);
      expect(b.containsKey('context'), isFalse);
    }
  });

  test(
    'allowlist gate: canon kept, noise + folded http + dropped metrics out',
    () async {
      final (collector, sender) = await _wire(flushAt: 1);

      // Non-canon → all dropped, nothing flushes.
      collector.add(const EdgeEvent.event('telemetry.initialized'));
      collector.add(const EdgeEvent.event('http.error'));
      collector.add(const EdgeEvent.event('http.slow_request'));
      collector.add(const EdgeEvent.event('performance.memory_pressure'));
      collector.add(const EdgeEvent.metric('http.response_time', 1));
      collector.add(const EdgeEvent.metric('network.quality_score', 4));
      collector.add(const EdgeEvent.metric('performance.startup_time', 1));
      await Future<void>(() {});
      expect(sender.sent, isEmpty);

      // Canon http.request survives (the fold target).
      collector.add(
        const EdgeEvent.event(
          'http.request',
          attributes: {'http.success': 'true'},
        ),
      );
      await Future<void>(() {});
      expect(sender.sent, hasLength(1));
      expect(
        (sender.sent.single['events'] as List).single['eventName'],
        'http.request',
      );
    },
  );

  test(
    'geo/tenant never reach the wire — from globals OR event attributes',
    () async {
      final (collector, sender) = await _wire(
        flushAt: 1,
        global: {
          'device.id': 'device_abc',
          'location': 'Nairobi', // global path
          'tenant_id': 't_1',
        },
      );

      // geo arrives via event attributes — must still be stripped (the merge in
      // Collector.add spreads event.attributes over the snapshot).
      collector.add(
        const EdgeEvent.event('navigation', attributes: {'geo': 'KE'}),
      );
      await Future<void>(() {});

      final attrs =
          (sender.sent.single['events'] as List).single['attributes'] as Map;
      expect(attrs.containsKey('location'), isFalse);
      expect(attrs.containsKey('tenant_id'), isFalse);
      expect(attrs.containsKey('geo'), isFalse);
    },
  );

  test('assembled batch matches the family-canon golden fixture', () async {
    final (collector, sender) = await _wire(flushAt: 2);
    collector.add(
      const EdgeEvent.event(
        'navigation',
        attributes: {'navigation.to': '/home'},
      ),
    );
    collector.add(const EdgeEvent.metric('frame_render_time', 12.5));
    await Future<void>(() {});

    final golden =
        (jsonDecode(
                File(
                  'test/fixtures/canon_telemetry_batch.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)
          ..remove('_comment');

    expect(_normalize(sender.sent.single), golden);
  });

  test('transport posts to the configured URL as given (R10)', () {
    Uri url(String endpoint) =>
        RetryTransport(endpoint: endpoint, queue: _NoopQueue()).resolvedUrl;

    for (final endpoint in [
      'https://h/collector-go/telemetry',
      'https://h/telemetry',
      'https://h/telemetry/', // a trailing slash is left as configured
      'https://h', // a bare base is NOT completed with a path any more
    ]) {
      expect(url(endpoint).toString(), endpoint);
    }
  });
}
