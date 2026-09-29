// lib/src/core/offline_queue.dart

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// FIFO on-disk queue for telemetry that failed to send.
///
/// One file per payload under `<app documents>/edge_telemetry_queue/`. Draining
/// lists the files in lexical order, POSTs each via the caller-supplied sender,
/// and deletes on success. Filenames are timestamp-named, so lexical order is
/// chronological *within* a prefix. Crashes drain first: a drain cycle is
/// capped at [drainBatchSize] files, so a batch backlog ahead of them would
/// starve the payloads this queue exists for. The stored bytes are the
/// assembled payload verbatim, so a drained retry is byte-identical to the
/// original send.
///
/// Two filename prefixes: `batch_` for normal batches (drop-oldest at
/// [maxQueueSize]) and `crash_` for crashes (drop-oldest at [maxCrashFiles]).
/// Crashes get their own, generous allowance rather than the v2 exemption:
/// "a crash is never dropped" is what made the re-POST amplification unbounded
/// once the payloads turned out to be undeliverable. Absorbs the v1.5.2
/// `CrashStorage`.
///
/// Every file also carries an attempt counter in its name (`…_aN.json`), bumped
/// by a rename on each failed drain. At [maxAttempts] the file is dropped: a
/// payload the collector will never take must be able to die.
class OfflineQueue {
  static const String _queueDir = 'edge_telemetry_queue';
  static const String _batchPrefix = 'batch_';
  static const String _crashPrefix = 'crash_';

  /// Monotonic tiebreak so two persists in the same millisecond keep a stable
  /// lexical (== insertion) order instead of colliding on one filename.
  static int _seq = 0;

  /// Files drained per cycle. The trigger stays the existing successful send —
  /// pacing, not a new timer, is what keeps a backlog from stampeding.
  static const int drainBatchSize = 5;

  /// Per-file delivery attempts before the payload is dropped.
  static const int maxAttempts = 5;

  final bool _debugMode;
  final int maxQueueSize;
  final int maxCrashFiles;

  /// Counts a payload the queue gave up on, by short stable reason slug — the
  /// same counter the off-canon drop and the tier shed use.
  final void Function(String reason)? onDrop;

  Directory? _dir;

  OfflineQueue({
    bool debugMode = false,
    this.maxQueueSize = 200,
    this.maxCrashFiles = 50,
    this.onDrop,
  }) : _debugMode = debugMode;

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
  /// [isCrash] files use the `crash_` prefix and their own [maxCrashFiles] cap.
  Future<String?> persist(Map<String, dynamic> payload,
      {bool isCrash = false}) async {
    if (_dir == null) await initialize();
    if (_dir == null) return null;

    try {
      final prefix = isCrash ? _crashPrefix : _batchPrefix;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final seq = (_seq++).toString().padLeft(6, '0');
      final filename = '$prefix${timestamp}_${seq}_a0.json';
      await File('${_dir!.path}/$filename').writeAsString(jsonEncode(payload));
      await _enforceCap(isCrash ? _crashPrefix : _batchPrefix);
      if (_debugMode) print('💾 Persisted payload to offline queue: $filename');
      return filename;
    } catch (e) {
      if (_debugMode) print('⚠️ Failed to persist payload: $e');
      return null;
    }
  }

  /// Drain the queue FIFO, at most [drainBatchSize] files per call. For each
  /// stored payload, call [send]; delete the file when it returns true.
  /// A false return bumps the file's attempt counter and drops it at
  /// [maxAttempts]. Returns the number of payloads successfully sent.
  Future<int> drain(Future<bool> Function(Map<String, dynamic>) send) async {
    if (_dir == null) await initialize();
    if (_dir == null) return 0;

    final files = await _queueFiles();
    // Crashes first, then FIFO within each prefix (lexical == chronological).
    files.sort((a, b) {
      final kind = (_isCrash(b) ? 1 : 0) - (_isCrash(a) ? 1 : 0);
      return kind != 0 ? kind : a.path.compareTo(b.path);
    });

    var sent = 0;
    for (final file in files.take(drainBatchSize)) {
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (e) {
        await file.delete(); // corrupt file — drop it
        onDrop?.call('queue_corrupt');
        continue;
      }
      if (await send(payload)) {
        await file.delete();
        sent++;
      } else {
        await _bumpAttempt(file);
      }
    }
    if (_debugMode && sent > 0) print('📤 Drained $sent payload(s) from queue');
    return sent;
  }

  /// Rename the file with its attempt count incremented; delete it at the
  /// ceiling. A rename keeps the stored bytes verbatim — the payload a retry
  /// POSTs is still byte-identical to the original send.
  Future<void> _bumpAttempt(File file) async {
    try {
      final name = file.uri.pathSegments.last;
      final m = RegExp(r'^(.*)_a(\d+)\.json$').firstMatch(name);
      if (m == null) return; // pre-v3 filename — leave it, it still drains
      final attempts = int.parse(m.group(2)!) + 1;
      if (attempts >= maxAttempts) {
        await file.delete();
        onDrop?.call('queue_attempts_exhausted');
        if (_debugMode) print('🗑️ Dropped $name after $attempts attempts');
        return;
      }
      await file.rename('${_dir!.path}/${m.group(1)}_a$attempts.json');
    } catch (e) {
      if (_debugMode) print('⚠️ Failed to bump attempt count: $e');
    }
  }

  Future<List<File>> _queueFiles() async {
    return _dir!
        .list()
        .where((e) => e is File && _isQueueFile(e))
        .cast<File>()
        .toList();
  }

  bool _isCrash(File f) => f.uri.pathSegments.last.startsWith(_crashPrefix);

  bool _isQueueFile(File f) {
    final name = f.uri.pathSegments.last;
    return name.endsWith('.json') &&
        (name.startsWith(_batchPrefix) || name.startsWith(_crashPrefix));
  }

  /// Drop the oldest files of one [prefix] once they exceed that prefix's cap.
  /// The two prefixes are capped independently, so a crash backlog can't starve
  /// batches and a batch flood can't evict crashes.
  Future<void> _enforceCap(String prefix) async {
    final cap = prefix == _crashPrefix ? maxCrashFiles : maxQueueSize;
    try {
      final files = (await _queueFiles())
          .where((f) => f.uri.pathSegments.last.startsWith(prefix))
          .toList();
      if (files.length <= cap) return;
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files.take(files.length - cap)) {
        await file.delete();
        onDrop?.call('queue_overflow');
      }
    } catch (e) {
      if (_debugMode) print('⚠️ Failed to enforce queue cap: $e');
    }
  }
}
