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
    this.batchSize = 30,
    // ponytail: 5-min flush kept byte-identical with v1.5.2 (the latent 60×
    // defect). The fix to flushIntervalMs=5s is the Phase-3 wire flip, not #18.
    this.flushInterval = const Duration(minutes: 5),
    this.debugMode = false,
  });

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
      'type': 'batch',
      'events': List<Map<String, dynamic>>.from(_buffer),
      'batch_size': _buffer.length,
      'timestamp': DateTime.now().toIso8601String(),
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
