// lib/src/core/offline_queue.dart

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// FIFO on-disk queue for telemetry that failed to send.
///
/// One file per payload under `<app documents>/edge_telemetry_queue/`. Draining
/// lists the files in lexical order, POSTs each via the caller-supplied sender,
/// and deletes on success. Filenames are timestamp-named, so lexical order is
/// chronological *within* a prefix; the two prefixes below drain as a group
/// (`batch_` before `crash_`), which is enough — both are sent, and cross-kind
/// ordering isn't load-bearing. The stored bytes are the assembled payload
/// verbatim, so a drained retry is byte-identical to the original send.
///
/// Two filename prefixes: `batch_` for normal batches (subject to the
/// [maxQueueSize] drop-oldest cap) and `crash_` for crashes (exempt from the
/// cap — a crash is never dropped). Absorbs the v1.5.2 `CrashStorage`.
class OfflineQueue {
  static const String _queueDir = 'edge_telemetry_queue';
  static const String _batchPrefix = 'batch_';
  static const String _crashPrefix = 'crash_';

  /// Monotonic tiebreak so two persists in the same millisecond keep a stable
  /// lexical (== insertion) order instead of colliding on one filename.
  static int _seq = 0;

  final bool _debugMode;
  final int maxQueueSize;
  Directory? _dir;

  OfflineQueue({bool debugMode = false, this.maxQueueSize = 200})
      : _debugMode = debugMode;

  Future<void> initialize() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _dir = Directory('${appDir.path}/$_queueDir');
      if (!await _dir!.exists()) {
        await _dir!.create(recursive: true);
      }
    } catch (e) {
      if (_debugMode) print('⚠️ Failed to initialize offline queue: $e');
    }
  }

  /// Persist a payload for later drain. Returns the filename, or null on failure.
  /// [isCrash] files use the `crash_` prefix and are exempt from the size cap.
  Future<String?> persist(Map<String, dynamic> payload,
      {bool isCrash = false}) async {
    if (_dir == null) await initialize();
    if (_dir == null) return null;

    try {
      final prefix = isCrash ? _crashPrefix : _batchPrefix;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final seq = (_seq++).toString().padLeft(6, '0');
      final filename = '$prefix${timestamp}_$seq.json';
      await File('${_dir!.path}/$filename').writeAsString(jsonEncode(payload));
      if (!isCrash) await _enforceCap();
      if (_debugMode) print('💾 Persisted payload to offline queue: $filename');
      return filename;
    } catch (e) {
      if (_debugMode) print('⚠️ Failed to persist payload: $e');
      return null;
    }
  }

  /// Drain the queue FIFO. For each stored payload, call [send]; delete the file
  /// only when it returns true. Returns the number of payloads successfully sent.
  Future<int> drain(Future<bool> Function(Map<String, dynamic>) send) async {
    if (_dir == null) await initialize();
    if (_dir == null) return 0;

    final files = await _queueFiles();
    files.sort((a, b) => a.path.compareTo(b.path)); // lexical == FIFO

    var sent = 0;
    for (final file in files) {
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (e) {
        await file.delete(); // corrupt file — drop it
        continue;
      }
      final ok = await send(payload);
      if (ok) {
        await file.delete();
        sent++;
      }
    }
    if (_debugMode && sent > 0) print('📤 Drained $sent payload(s) from queue');
    return sent;
  }

  Future<List<File>> _queueFiles() async {
    return _dir!
        .list()
        .where((e) => e is File && _isQueueFile(e))
        .cast<File>()
        .toList();
  }

  bool _isQueueFile(File f) {
    final name = f.uri.pathSegments.last;
    return name.endsWith('.json') &&
        (name.startsWith(_batchPrefix) || name.startsWith(_crashPrefix));
  }

  bool _isCrash(File f) => f.uri.pathSegments.last.startsWith(_crashPrefix);

  /// Drop the oldest batch files once they exceed [maxQueueSize]. Crash files
  /// are exempt — they never count toward the cap and are never dropped.
  Future<void> _enforceCap() async {
    try {
      final batches = (await _queueFiles()).where((f) => !_isCrash(f)).toList();
      if (batches.length <= maxQueueSize) return;
      batches.sort((a, b) => a.path.compareTo(b.path));
      for (final file in batches.take(batches.length - maxQueueSize)) {
        await file.delete();
      }
    } catch (e) {
      if (_debugMode) print('⚠️ Failed to enforce queue cap: $e');
    }
  }
}
