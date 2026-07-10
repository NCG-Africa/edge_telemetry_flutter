// lib/src/core/offline_queue.dart

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// FIFO on-disk queue for telemetry that failed to send.
///
/// One file per payload under `<app documents>/edge_telemetry_queue/`. Draining
/// lists the files in lexical (== chronological, timestamp-named) order, POSTs
/// each via the caller-supplied sender, and deletes on success. The stored bytes
/// are the assembled payload verbatim, so a drained retry is byte-identical to
/// the original send.
///
/// Absorbs the v1.5.2 `CrashStorage` — the single unified persistence rail.
// ponytail: crash-only in Phase 2 (only the crash rail persists on failure).
// Normal-batch persistence + the ~200 drop-oldest cap + crash-exempt policy are
// reliability work owned by #9. Drop-oldest is kept at the old 100 for parity.
class OfflineQueue {
  static const String _queueDir = 'edge_telemetry_queue';
  static const String _filePrefix = 'crash_';
  static const int _maxStored = 100;

  final bool _debugMode;
  Directory? _dir;

  OfflineQueue({bool debugMode = false}) : _debugMode = debugMode;

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
  Future<String?> persist(Map<String, dynamic> payload) async {
    if (_dir == null) await initialize();
    if (_dir == null) return null;

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = '$_filePrefix$timestamp.json';
      await File('${_dir!.path}/$filename').writeAsString(jsonEncode(payload));
      await _enforceCap();
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
        .where((e) => e is File && e.path.contains(_filePrefix))
        .cast<File>()
        .toList();
  }

  /// Drop the oldest files once the queue exceeds the cap.
  Future<void> _enforceCap() async {
    try {
      final files = await _queueFiles();
      if (files.length <= _maxStored) return;
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files.take(files.length - _maxStored)) {
        await file.delete();
      }
    } catch (e) {
      if (_debugMode) print('⚠️ Failed to enforce queue cap: $e');
    }
  }
}
