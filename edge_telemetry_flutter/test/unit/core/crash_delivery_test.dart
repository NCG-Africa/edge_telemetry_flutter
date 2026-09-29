// test/unit/core/crash_delivery_test.dart
//
// Delivery-rail wire seams (#81). The crash rail never delivered in v2: it
// POSTed a bare wire item, the collector answered 400, and the payload parked
// in a cap-exempt file that was re-POSTed forever. These tests pin the three
// fixes that make a crash arrive — the envelope, the 4xx death, and the gzip
// downgrade probe — against a real HttpServer, because "what left the socket"
// is the only honest assertion about a wire contract.

import 'dart:convert';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/pipeline.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// One POST as the server saw it.
class _Post {
  _Post(this.body, this.encoding);
  final Map<String, dynamic> body;
  final String? encoding;

  bool get gzipped => encoding == 'gzip';
}

/// A collector that answers from [statuses] in order, last status repeating,
/// and records every request body it could decode.
class _FakeCollector {
  _FakeCollector(this.statuses);
  final List<int> statuses;
  final List<_Post> posts = [];
  late final HttpServer _server;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final encoding = req.headers.value('Content-Encoding');
      final raw = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      final bytes = encoding == 'gzip' ? GZipCodec().decode(raw) : raw;
      posts.add(_Post(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>, encoding));
      req.response.statusCode = statuses[posts.length > statuses.length
          ? statuses.length - 1
          : posts.length - 1];
      await req.response.close();
    });
    return 'http://${_server.address.host}:${_server.port}';
  }

  Future<void> stop() => _server.close(force: true);
}

/// In-memory queue: records persists, replays a seeded backlog on drain.
class _FakeQueue extends OfflineQueue {
  _FakeQueue({List<Map<String, dynamic>>? stored})
      : stored = stored ?? [],
        super();

  final List<Map<String, dynamic>> stored;
  final List<Map<String, dynamic>> persisted = [];
  final List<String> drops = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> persist(Map<String, dynamic> payload,
      {bool isCrash = false}) async {
    persisted.add(payload);
    return 'rec_${persisted.length}.json';
  }

  @override
  Future<int> drain(
      Future<DrainResult> Function(Map<String, dynamic>) send) async {
    var sent = 0;
    for (final p in List.of(stored)) {
      if (await send(p) == DrainResult.done) {
        stored.remove(p);
        sent++;
      }
    }
    return sent;
  }
}

const _crashItem = {
  'type': 'event',
  'eventName': 'app.crash',
  'timestamp': '2026-01-01T00:00:00.000',
  'attributes': {'message': 'boom', 'session.id': 's-1', 'is_fatal': 'true'},
};

void main() {
  setUp(RetryTransport.resetGzipProbe);
  tearDown(RetryTransport.resetGzipProbe);

  test('the immediate rail POSTs a one-item telemetry_batch, not a bare item',
      () async {
    final collector = _FakeCollector([200]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    final transport = RetryTransport(endpoint: endpoint, queue: _FakeQueue());
    Pipeline(transport: transport).sendNow(Map.of(_crashItem));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final body = collector.posts.single.body;
    expect(body.keys.toList(), ['type', 'timestamp', 'batch_size', 'events']);
    expect(body['type'], 'telemetry_batch');
    expect(body['batch_size'], 1);
    // Self-describing: the item carries its own context block, so a payload
    // drained days later still says who and when it was.
    final item = (body['events'] as List).single as Map<String, dynamic>;
    expect(item['eventName'], 'app.crash');
    expect(item['attributes'], containsPair('session.id', 's-1'));
  });

  test('a legacy bare stored payload is re-wrapped on drain', () async {
    final collector = _FakeCollector([200]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    // Exactly what v2.0.0 left on disk: a bare wire item, no envelope.
    final queue = _FakeQueue(stored: [Map.of(_crashItem)]);
    await RetryTransport(endpoint: endpoint, queue: queue).drainQueue();

    final body = collector.posts.single.body;
    expect(body['type'], 'telemetry_batch');
    expect(body['batch_size'], 1);
    expect((body['events'] as List).single, _crashItem);
    expect(queue.stored, isEmpty); // backlog cleared
  });

  test('an already-enveloped stored payload drains verbatim', () async {
    final collector = _FakeCollector([200]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    final envelope = {
      'type': 'telemetry_batch',
      'timestamp': '2026-01-01T00:00:00.000',
      'batch_size': 1,
      'events': [Map.of(_crashItem)],
    };
    await RetryTransport(
        endpoint: endpoint, queue: _FakeQueue(stored: [envelope])).drainQueue();

    expect(collector.posts.single.body, envelope); // not double-wrapped
  });

  test('a 4xx batch is dropped and counted by status, never retried or queued',
      () async {
    final collector = _FakeCollector([422]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    final queue = _FakeQueue();
    final drops = <String>[];
    final transport = RetryTransport(
      endpoint: endpoint,
      queue: queue,
      backoff: const [Duration.zero, Duration.zero, Duration.zero],
      onDrop: drops.add,
    );

    expect(await transport.send({'type': 'telemetry_batch', 'events': []}),
        isFalse);
    expect(collector.posts, hasLength(1)); // no retry
    expect(queue.persisted, isEmpty); // no queue
    expect(drops, ['http_422']);
  });

  test('a 4xx crash is dropped, not stored offline', () async {
    final collector = _FakeCollector([422]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    final queue = _FakeQueue();
    final drops = <String>[];
    await RetryTransport(endpoint: endpoint, queue: queue, onDrop: drops.add)
        .sendImmediate({
      'type': 'telemetry_batch',
      'batch_size': 1,
      'events': [Map.of(_crashItem)],
    });

    expect(queue.persisted, isEmpty);
    expect(drops, ['http_422']);
  });

  test('a 4xx on drain deletes the file instead of re-POSTing it forever',
      () async {
    final collector = _FakeCollector([400, 400]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    final queue = _FakeQueue(stored: [Map.of(_crashItem)]);
    final drops = <String>[];
    final transport =
        RetryTransport(endpoint: endpoint, queue: queue, onDrop: drops.add);

    await transport.drainQueue();

    expect(queue.stored, isEmpty); // dropped, not parked
    // 400 spends the one-shot gzip probe: compressed POST, then the plain retry.
    expect(collector.posts, hasLength(2));
    expect(drops, ['http_400']);
  });

  test('gzip ships unconditionally', () async {
    final collector = _FakeCollector([200]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    await RetryTransport(endpoint: endpoint, queue: _FakeQueue())
        .send({'type': 'telemetry_batch', 'events': []});

    expect(collector.posts.single.gzipped, isTrue);
  });

  test(
      'a rejecting-then-accepting collector costs exactly one wasted POST, '
      'and no config is read', () async {
    // 400 to the first (gzipped) POST, 200 to everything after: the collector
    // that cannot decompress. No flag, no version endpoint — the probe is the
    // capability check.
    final collector = _FakeCollector([400, 200]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    final transport = RetryTransport(endpoint: endpoint, queue: _FakeQueue());

    for (var i = 0; i < 4; i++) {
      expect(await transport.send({'type': 'telemetry_batch', 'events': []}),
          isTrue);
    }

    // 4 sends → 5 POSTs: the one rejected gzipped probe plus four plain ones.
    expect(collector.posts, hasLength(5));
    expect(collector.posts.first.gzipped, isTrue); // the wasted POST
    expect(collector.posts.skip(1).every((p) => !p.gzipped), isTrue);
  });

  test('the probe is spent even when the uncompressed retry also fails',
      () async {
    // 400 to everything: the payload was simply bad, not the encoding. gzip
    // stays on and no further POST is ever wasted probing.
    final collector = _FakeCollector([400]);
    final endpoint = await collector.start();
    addTearDown(collector.stop);

    final transport = RetryTransport(
        endpoint: endpoint,
        queue: _FakeQueue(),
        backoff: const [Duration.zero]);

    await transport.send({'type': 'telemetry_batch', 'events': []});
    await transport.send({'type': 'telemetry_batch', 'events': []});

    expect(collector.posts, hasLength(3)); // probe + plain, then one gzipped
    expect(collector.posts.last.gzipped, isTrue); // still compressing
  });
}
