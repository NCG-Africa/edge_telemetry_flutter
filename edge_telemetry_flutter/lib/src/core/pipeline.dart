// lib/src/core/pipeline.dart

import 'dart:async' show Timer;

import 'package:flutter/foundation.dart' show mapEquals;

import 'retry_transport.dart';
import 'wire_canon.dart';

/// Buffers batched events and dispatches both the batched and immediate paths
/// through the one [RetryTransport].
///
/// Absorbs the batching half of the v1.5.2 `JsonEventTracker`. Transport- and
/// crash-agnostic: both paths build the same envelope / hand off to the same
/// transport.
class Pipeline {
  final RetryTransport transport;
  final int batchSize;
  final Duration flushInterval;
  final bool debugMode;

  final List<Map<String, dynamic>> _buffer = [];
  Timer? _timer;

  /// The hoisted context block for whatever is currently buffered (#82). Empty
  /// while the hoist is off, and then `telemetryBatch` omits the block entirely.
  Map<String, String> _context = const {};

  Pipeline({
    required this.transport,
    int batchSize = 30,
    this.flushInterval = const Duration(seconds: 5),
    this.debugMode = false,
    // ponytail: Collector caps batches at 1000 (collector-contract §2); clamp
    // the flush threshold so the buffer can never exceed it.
  }) : batchSize = batchSize.clamp(1, 1000);

  /// Buffer a batched event; flush when the buffer hits [batchSize].
  ///
  /// [context] is the item's hoisted context block (#82), empty while the hoist
  /// is off. A batch carries exactly one such block, so a change to it closes
  /// the current batch before this event joins one.
  void enqueue(Map<String, dynamic> event,
      {Map<String, String> context = const {}}) {
    // One batch is structurally one session and one user. Whole-map equality
    // rather than a session.id/user.id check: it is the same one line, and it
    // makes the server-side merge byte-exact by construction for *every*
    // hoisted key, the live-but-batch-scoped ones included (network.type, and
    // the `device.` keys re-read per snapshot). Deliberately stronger than
    // "session or user change forces a flush" — the cost is an extra batch on
    // a network or brightness flip, which is rare and self-announcing.
    //
    // Per-item override is deliberately declined here: an item does not keep
    // its own copy of a hoisted key to win with at merge time. That precedence
    // rule is for a value frozen at a different *instant* than the batch — a
    // later reading of the same thing. A value belonging to a different
    // *session* is not that; merging it in would put two sessions in one batch,
    // which is the corruption this flush exists to prevent.
    if (_buffer.isNotEmpty && !mapEquals(_context, context)) _flush();
    _context = context;
    _buffer.add(event);
    if (debugMode) {
      print('📦 Queued event (${_buffer.length}/$batchSize): '
          '${event['eventName'] ?? event['metricName'] ?? 'unknown'}');
    }
    if (_buffer.length >= batchSize) {
      _flush();
    } else {
      _resetTimer();
    }
  }

  /// Send a single wire item immediately, bypassing the batch (crash rail).
  /// Enveloped as a one-item `telemetry_batch` — the collector rejects a bare
  /// item with a 400, which is why no crash was ever delivered in v2.
  void sendNow(Map<String, dynamic> item) {
    transport.sendImmediate(telemetryBatch([item]));
  }

  /// Force-send any buffered events (call on shutdown).
  void flush() {
    if (_buffer.isNotEmpty) _flush();
  }

  void _flush() {
    if (_buffer.isEmpty) return;
    transport.send(telemetryBatch(List<Map<String, dynamic>>.from(_buffer),
        context: _context));
    if (debugMode) print('📤 Sent batch of ${_buffer.length} events');
    _buffer.clear();
    _context = const {};
    _timer?.cancel();
  }

  void _resetTimer() {
    _timer?.cancel();
    _timer = Timer(flushInterval, () {
      if (_buffer.isNotEmpty) _flush();
    });
  }

  void dispose() {
    // Release the timer only. Buffered events are dropped, matching v1.5.2
    // (flush-on-shutdown is a wire-behaviour change deferred).
    _timer?.cancel();
  }
}
