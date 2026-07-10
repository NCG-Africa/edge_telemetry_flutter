// lib/src/core/retry_transport.dart

import 'dart:convert';
import 'dart:io';

import 'offline_queue.dart';

/// Low-level POST primitive. Returns true on a 2xx response. Injectable so tests
/// can drive the transport without real network I/O.
typedef Sender = Future<bool> Function(Map<String, dynamic> payload);

/// The single network rail: POSTs assembled payloads and, for the crash path,
/// persists to the [OfflineQueue] on failure and drains it on reconnect.
///
/// Absorbs the v1.5.2 `JsonHttpClient` (the POST) and `CrashRetryManager`
/// (persist + drain). One persistence/backoff system, not two.
class RetryTransport {
  final String endpoint;
  final OfflineQueue queue;
  final bool debugMode;

  final HttpClient _httpClient;
  final Sender? _sender;

  RetryTransport({
    required this.endpoint,
    required this.queue,
    this.debugMode = false,
    HttpClient? httpClient,
    Sender? sender,
  })  : _httpClient = httpClient ?? HttpClient(),
        _sender = sender;

  /// Send a batch. Byte-identical to v1.5.2 `JsonHttpClient.sendTelemetryData`.
  /// On success, opportunistically drains any queued crash payloads.
  // ponytail: normal-batch failures are dropped (not persisted), matching
  // v1.5.2. Persisting normal batches is reliability work owned by #9.
  Future<bool> send(Map<String, dynamic> batch) async {
    final ok = await _sendRaw(batch);
    if (ok) await drainQueue();
    return ok;
  }

  /// Send a crash immediately, bypassing the batch. On failure, persist to the
  /// offline queue so a crash that kills the app still arrives on next launch.
  Future<void> sendImmediate(Map<String, dynamic> crashData) async {
    final ok = await _sendRaw(crashData);
    if (ok) {
      // Error-report send logs are intentionally always printed (see CLAUDE.md).
      print('✅ Error report sent successfully');
      print('   📊 Error: ${crashData['error']}');
      if (crashData['fingerprint'] != null) {
        print('   🔍 Fingerprint: ${crashData['fingerprint']}');
      }
      final attrs = crashData['attributes'];
      if (attrs is Map) {
        if (attrs['user.id'] != null) print('   👤 User: ${attrs['user.id']}');
        if (attrs['session.id'] != null) {
          print('   🔄 Session: ${attrs['session.id']}');
        }
      }
      print('   ⏰ Timestamp: ${crashData['timestamp']}');
      await drainQueue();
    } else {
      print('❌ Failed to send error report, storing offline');
      final filename = await queue.persist(crashData);
      if (filename != null) {
        print('💾 Error report stored for retry: $filename');
      }
    }
  }

  /// Drain queued payloads through the same POST primitive.
  Future<void> drainQueue() => queue.drain(_sendRaw);

  /// The one POST primitive. Injected [Sender] wins (tests); otherwise real HTTP.
  Future<bool> _sendRaw(Map<String, dynamic> data) {
    final sender = _sender;
    if (sender != null) return sender(data);
    return _httpPost(data);
  }

  Future<bool> _httpPost(Map<String, dynamic> data) async {
    try {
      final request = await _httpClient.postUrl(Uri.parse(endpoint));
      request.headers.set('Content-Type', 'application/json');
      request.write(json.encode(data));
      final response = await request.close();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        print('✅ Sent telemetry data successfully');
        return true;
      }
      print('❌ Failed: HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      print('❌ Error: $e');
      return false;
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
