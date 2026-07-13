// test/unit/core/offline_queue_test.dart
//
// Reliability-rail seams (#23): file-per-batch persist, lexical FIFO drain,
// verbatim bytes, ~cap drop-oldest, and the crash-exempt policy. Runs against a
// real temp dir via a faked PathProviderPlatform — no mocking of the queue.

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
        await File('${docs.path}/edge_telemetry_queue/${files.single}')
            .readAsString();
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
      return true; // 2xx
    });

    expect(count, 3);
    expect(drained, [0, 1, 2]); // FIFO
    expect(await queuedFiles(), isEmpty); // deleted on 2xx
  });

  test('keeps files whose send fails (no delete on non-2xx)', () async {
    final q = OfflineQueue();
    await q.persist({'n': 0});

    final count = await q.drain((_) async => false);
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
      return true;
    });

    expect(surviving, hasLength(3));
    expect(surviving, [3, 4, 5]); // oldest three dropped
  });

  test('crashes are exempt from the cap', () async {
    final q = OfflineQueue(maxQueueSize: 2);
    for (var i = 0; i < 5; i++) {
      await q.persist({'c': i}, isCrash: true);
    }
    // A couple of normal batches alongside the crashes.
    await q.persist({'b': 0});
    await q.persist({'b': 1});
    await q.persist({'b': 2}); // trips the cap → drops oldest batch

    final files = await queuedFiles();
    final crashes = files.where((f) => f.startsWith('crash_'));
    final batches = files.where((f) => f.startsWith('batch_'));
    expect(crashes, hasLength(5)); // all crashes kept
    expect(batches, hasLength(2)); // batches capped at 2
  });
}
