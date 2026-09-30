// test/unit/core/offline_queue_test.dart
//
// Reliability-rail seams (#23): file-per-batch persist, lexical FIFO drain,
// verbatim bytes, and drop-oldest caps. #81 replaces the crash *exemption* with
// a generous crash cap plus a per-file attempt ceiling, and paces the drain.
// Runs against a real temp dir via a faked PathProviderPlatform — no mocking.

import 'dart:io';

import 'package:edge_telemetry_flutter/src/core/offline_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Points `getApplicationDocumentsDirectory()` at a real temp dir.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

void main() {
  late Directory docs;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('edge_queue_test');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
  });

  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  Future<List<String>> queuedFiles() async {
    final dir = Directory('${docs.path}/edge_telemetry_queue');
    if (!await dir.exists()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
  }

  test('persists one file per batch, bytes verbatim', () async {
    final q = OfflineQueue();
    await q.persist({'type': 'telemetry_batch', 'events': []});

    final files = await queuedFiles();
    expect(files, hasLength(1));
    expect(files.single, startsWith('batch_'));

    final content =
        await File(
          '${docs.path}/edge_telemetry_queue/${files.single}',
        ).readAsString();
    expect(content, '{"type":"telemetry_batch","events":[]}');
  });

  test('drains FIFO in lexical order and deletes on success', () async {
    final q = OfflineQueue();
    for (var i = 0; i < 3; i++) {
      await q.persist({'n': i});
    }

    final drained = <int>[];
    final count = await q.drain((p) async {
      drained.add(p['n'] as int);
      return DrainResult.done; // 2xx
    });

    expect(count, 3);
    expect(drained, [0, 1, 2]); // FIFO
    expect(await queuedFiles(), isEmpty); // deleted on 2xx
  });

  test('keeps files whose send fails (no delete on non-2xx)', () async {
    final q = OfflineQueue();
    await q.persist({'n': 0});

    final count = await q.drain((_) async => DrainResult.failed);
    expect(count, 0);
    expect(await queuedFiles(), hasLength(1));
  });

  test('cap drops oldest batches beyond maxQueueSize', () async {
    final q = OfflineQueue(maxQueueSize: 3);
    for (var i = 0; i < 6; i++) {
      await q.persist({'n': i});
    }

    final surviving = <int>[];
    await q.drain((p) async {
      surviving.add(p['n'] as int);
      return DrainResult.done;
    });

    expect(surviving, hasLength(3));
    expect(surviving, [3, 4, 5]); // oldest three dropped
  });

  test('the two prefixes are capped independently', () async {
    final q = OfflineQueue(maxQueueSize: 2, maxCrashFiles: 3);
    for (var i = 0; i < 5; i++) {
      await q.persist({'c': i}, isCrash: true);
    }
    for (var i = 0; i < 4; i++) {
      await q.persist({'b': i});
    }

    final files = await queuedFiles();
    expect(files.where((f) => f.startsWith('crash_')), hasLength(3));
    expect(files.where((f) => f.startsWith('batch_')), hasLength(2));
  });

  test('crashes lose the cap exemption: drop-oldest, counted', () async {
    final drops = <String>[];
    final q = OfflineQueue(maxCrashFiles: 2, onDrop: drops.add);
    for (var i = 0; i < 5; i++) {
      await q.persist({'c': i}, isCrash: true);
    }

    final kept = <int>[];
    await q.drain((p) async {
      kept.add(p['c'] as int);
      return DrainResult.done;
    });

    expect(kept, [3, 4]); // oldest three dropped
    expect(drops, ['queue_overflow', 'queue_overflow', 'queue_overflow']);
  });

  test(
    'a file is dropped and counted once its attempts are exhausted',
    () async {
      final drops = <String>[];
      final q = OfflineQueue(onDrop: drops.add);
      await q.persist({'c': 0}, isCrash: true);

      var attempts = 0;
      for (var cycle = 0; cycle < OfflineQueue.maxAttempts + 1; cycle++) {
        await q.drain((_) async {
          attempts++;
          return DrainResult.failed; // collector keeps refusing
        });
      }

      expect(attempts, OfflineQueue.maxAttempts);
      expect(await queuedFiles(), isEmpty);
      expect(drops, ['queue_attempts_exhausted']);
    },
  );

  test(
    'an offline cycle spends no attempts and leaves the queue untouched',
    () async {
      final drops = <String>[];
      final q = OfflineQueue(onDrop: drops.add);
      for (var i = 0; i < 3; i++) {
        await q.persist({'c': i}, isCrash: true);
      }

      var calls = 0;
      for (var cycle = 0; cycle < OfflineQueue.maxAttempts + 2; cycle++) {
        await q.drain((_) async {
          calls++;
          return DrainResult.offline; // no network — nothing learned
        });
      }

      expect(
        calls,
        OfflineQueue.maxAttempts + 2,
      ); // one probe per cycle, then stop
      expect(await queuedFiles(), hasLength(3)); // nothing dropped
      expect(drops, isEmpty);
    },
  );

  test('drain is paced at drainBatchSize files per cycle', () async {
    final q = OfflineQueue();
    for (var i = 0; i < 12; i++) {
      await q.persist({'n': i});
    }

    expect(
      await q.drain((_) async => DrainResult.done),
      OfflineQueue.drainBatchSize,
    );
    expect(await queuedFiles(), hasLength(12 - OfflineQueue.drainBatchSize));
  });

  test('crashes drain ahead of an older batch backlog', () async {
    final q = OfflineQueue();
    for (var i = 0; i < 6; i++) {
      await q.persist({'b': i}); // queued first — older
    }
    await q.persist({'c': 0}, isCrash: true);

    final seen = <Map<String, dynamic>>[];
    await q.drain((p) async {
      seen.add(p);
      return DrainResult.done;
    });

    expect(seen.first, {'c': 0});
  });
}
