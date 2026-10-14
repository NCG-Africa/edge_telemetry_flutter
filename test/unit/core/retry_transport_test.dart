// test/unit/core/retry_transport_test.dart
//
// Reliability-rail seams (#23): the [0,2s,8s,30s] backoff-then-queue on a
// reachable failure, immediate queue when offline (status==0), and the
// X-API-Key header on the real POST.

import 'dart:async';
import 'dart:io';

import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:edge_telemetry_flutter/src/core/retry_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory queue that records what got persisted — no disk, no path_provider.
class _RecordingQueue extends OfflineQueue {
  final List<Map<String, dynamic>> persisted = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> persist(
    Map<String, dynamic> payload, {
    bool isCrash = false,
  }) async {
    persisted.add(payload);
    return 'rec_${persisted.length}.json';
  }

  @override
  Future<int> drain(
    Future<DrainResult> Function(Map<String, dynamic>) send,
  ) async => 0;
}

void main() {
  test(
    'reachable failure exhausts the backoff, then queues the batch',
    () async {
      final queue = _RecordingQueue();
      var attempts = 0;
      final transport = RetryTransport(
        endpoint: 'https://example.test',
        queue: queue,
        backoff: const [Duration.zero, Duration.zero, Duration.zero],
        sender: (_) async {
          attempts++;
          return false; // reachable failure (500)
        },
      );

      final ok = await transport.send({'type': 'telemetry_batch'});

      expect(ok, isFalse);
      expect(attempts, 3); // all backoff slots tried
      expect(queue.persisted, hasLength(1)); // queued after exhaustion
    },
  );

  test(
    'offline (status==0) queues immediately without burning backoff',
    () async {
      final queue = _RecordingQueue();
      // Port 1 refuses the connection → real HTTP path returns status 0.
      final transport = RetryTransport(
        endpoint: 'http://localhost:1',
        queue: queue,
        // Long delays that must NOT be awaited if the offline shortcut works.
        backoff: const [Duration.zero, Duration(seconds: 30)],
      );

      final sw = Stopwatch()..start();
      final ok = await transport.send({'type': 'telemetry_batch'});
      sw.stop();

      expect(ok, isFalse);
      expect(queue.persisted, hasLength(1));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5))); // no 30s wait
    },
  );

  test('sends the X-API-Key header on the real POST', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? seenKey;
    String? seenPath;
    server.listen((req) async {
      seenKey = req.headers.value('X-API-Key');
      seenPath = req.uri.path;
      await req.drain<void>();
      req.response.statusCode = 200;
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    final queue = _RecordingQueue();
    final transport = RetryTransport(
      endpoint:
          'http://${server.address.host}:${server.port}/collector-go/telemetry',
      apiKey: 'secret-123',
      queue: queue,
    );

    final ok = await transport.send({'type': 'telemetry_batch', 'events': []});

    expect(ok, isTrue);
    expect(seenKey, 'secret-123');
    expect(seenPath, '/collector-go/telemetry'); // as given (R10)
    expect(queue.persisted, isEmpty); // success → nothing queued
  });

  // SDK-003 (#120): release builds print no identifier and no error content —
  // over the real POST, so the network-error print is exercised too. Exactly
  // one line per outcome: the crash rail's own, not the batch rail's as well.
  for (final (status, expected) in [
    (200, '✅ Error report sent successfully'),
    (404, '❌ Error report rejected (HTTP 404), dropped'),
    (0, '❌ Failed to send error report, storing offline'),
  ]) {
    test('debugMode=false: crash send (HTTP $status) prints one line, '
        'no id or error content', () async {
      var endpoint = 'http://localhost:1'; // refused → offline (status 0)
      if (status != 0) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          await req.drain<void>();
          req.response.statusCode = status;
          await req.response.close();
        });
        addTearDown(() => server.close(force: true));
        endpoint = 'http://${server.address.host}:${server.port}/t';
      }
      final transport = RetryTransport(
        endpoint: endpoint,
        queue: _RecordingQueue(),
      );
      final logged = <String>[];
      await runZoned(
        () => transport.sendImmediate({
          'type': 'telemetry_batch',
          'timestamp': '2026-10-14T00:00:00Z',
          'events': [
            {
              'attributes': {
                'message': 'secret-message',
                'crash.source': 'secret-source',
                'user.id': 'secret-user',
                'session.id': 'secret-session',
              },
            },
          ],
        }),
        zoneSpecification: ZoneSpecification(
          print: (_, __, ___, line) => logged.add(line),
        ),
      );

      expect(logged, [expected]);
    });
  }
}
