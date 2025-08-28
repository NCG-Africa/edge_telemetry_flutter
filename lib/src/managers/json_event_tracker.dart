// lib/src/managers/json_event_tracker.dart

import 'dart:async';

import '../core/interfaces/event_tracker.dart';
import '../http/json_http_client.dart';

class JsonEventTracker implements EventTracker {
  final JsonHttpClient _httpClient;
  final Map<String, String> Function() _getAttributes;
  final int _batchSize;
  final bool _debugMode;

  // Batching state
  final List<Map<String, dynamic>> _eventQueue = [];
  Timer? _timeoutTimer;

  JsonEventTracker(
    this._httpClient,
    this._getAttributes, {
    int batchSize = 30,
    bool debugMode = false,
  })  : _batchSize = batchSize,
        _debugMode = debugMode;

  @override
  void trackEvent(String eventName, {Map<String, String>? attributes}) {
    final eventData = {
      'type': 'event',
      'eventName': eventName,
      'timestamp': DateTime.now().toIso8601String(),
      'attributes': {
        ..._getAttributes(),
        ...?attributes,
      },
    };

    _addToBatch(eventData);
  }

  @override
  void trackMetric(String metricName, double value,
      {Map<String, String>? attributes}) {
    final metricData = {
      'type': 'metric',
      'metricName': metricName,
      'value': value,
      'timestamp': DateTime.now().toIso8601String(),
      'attributes': {
        ..._getAttributes(),
        ...?attributes,
      },
    };

    _addToBatch(metricData);
  }

  @override
  void trackError(Object error,
      {StackTrace? stackTrace, Map<String, String>? attributes}) {
    final errorData = {
      'type': 'error',
      'error': error.toString(),
      'timestamp': DateTime.now().toIso8601String(),
      'attributes': {
        ..._getAttributes(),
        ...?attributes,
      },
      if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      // Extract fingerprint from attributes for top-level crash data
      if (attributes?['crash.fingerprint'] != null)
        'fingerprint': attributes!['crash.fingerprint'],
    };

    _httpClient.sendTelemetryData(errorData);

    if (_debugMode) {
      print('🚨 Error sent immediately (bypassed batching)');
      if (attributes?['crash.fingerprint'] != null) {
        print('🔍 Crash fingerprint: ${attributes!['crash.fingerprint']}');
      }
    }
  }

  /// Add event to batch queue
  void _addToBatch(Map<String, dynamic> eventData) {
    _eventQueue.add(eventData);

    if (_debugMode) {
      print(
          '📦 Queued event (${_eventQueue.length}/$_batchSize): ${eventData['eventName'] ?? eventData['metricName'] ?? 'unknown'}');
    }

    // Send batch when we reach the limit
    if (_eventQueue.length >= _batchSize) {
      _sendBatch();
    } else {
      // Reset timeout timer - send after 5 minutes if batch not full
      _resetTimeoutTimer();
    }
  }

  /// Send the current batch
  void _sendBatch() {
    if (_eventQueue.isEmpty) return;

    final batch = {
      'type': 'batch',
      'events': List.from(_eventQueue),
      'batch_size': _eventQueue.length,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _httpClient.sendTelemetryData(batch);

    if (_debugMode) {
      print('📤 Sent batch of ${_eventQueue.length} events');
    }

    _eventQueue.clear();
    _timeoutTimer?.cancel();
  }

  /// Reset timeout timer (send partial batch after 5 minutes)
  void _resetTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(Duration(minutes: 5), () {
      if (_eventQueue.isNotEmpty) {
        if (_debugMode) {
          print(
              '⏰ Timeout: Sending partial batch of ${_eventQueue.length} events');
        }
        _sendBatch();
      }
    });
  }

  /// Force send any remaining events (call on app dispose)
  void flush() {
    if (_eventQueue.isNotEmpty) {
      if (_debugMode) {
        print('🧹 Flushing remaining ${_eventQueue.length} events');
      }
      _sendBatch();
    }
  }

  /// Get current queue status
  Map<String, dynamic> getBatchStatus() {
    return {
      'queued_events': _eventQueue.length,
      'batch_size': _batchSize,
      'progress': '${_eventQueue.length}/$_batchSize',
      'timeout_active': _timeoutTimer?.isActive ?? false,
    };
  }

  void dispose() {
    flush(); // Send any remaining events
    _timeoutTimer?.cancel();
  }
}
