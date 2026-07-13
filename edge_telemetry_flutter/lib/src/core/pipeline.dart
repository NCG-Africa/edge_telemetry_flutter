// lib/src/core/pipeline.dart

import 'dart:async' show Timer;

import 'retry_transport.dart';

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

  Pipeline({
    required this.transport,
    int batchSize = 30,
    this.flushInterval = const Duration(seconds: 5),
    this.debugMode = false,
    // ponytail: Collector caps batches at 1000 (collector-contract §2); clamp
    // the flush threshold so the buffer can never exceed it.
  }) : batchSize = batchSize.clamp(1, 1000);

  /// Buffer a batched event; flush when the buffer hits [batchSize].
  void enqueue(Map<String, dynamic> event) {
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

  /// Send a single payload immediately, bypassing the batch (crash rail).
  void sendNow(Map<String, dynamic> payload) {
    transport.sendImmediate(payload);
  }

  /// Force-send any buffered events (call on shutdown).
  void flush() {
    if (_buffer.isNotEmpty) _flush();
  }

  void _flush() {
    if (_buffer.isEmpty) return;
    final batch = {
      'type': 'telemetry_batch',
      'timestamp': DateTime.now().toIso8601String(),
      'batch_size': _buffer.length,
      'events': List<Map<String, dynamic>>.from(_buffer),
    };
    transport.send(batch);
    if (debugMode) print('📤 Sent batch of ${_buffer.length} events');
    _buffer.clear();
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
