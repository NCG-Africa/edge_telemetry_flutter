// lib/src/core/retry_transport.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

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
  final String? apiKey;
  final OfflineQueue queue;
  final bool debugMode;

  final HttpClient _httpClient;
  final Sender? _sender;

  /// The resolved POST target: `<endpoint>/collector/telemetry` (family canon),
  /// unless [endpoint] already ends with that path.
  final Uri _url;

  RetryTransport({
    required this.endpoint,
    required this.queue,
    this.apiKey,
    this.debugMode = false,
    HttpClient? httpClient,
    Sender? sender,
  })  : _httpClient = httpClient ?? HttpClient(),
        _sender = sender,
        _url = _resolveUrl(endpoint);

  /// The resolved POST target (test seam).
  @visibleForTesting
  Uri get resolvedUrl => _url;

  static Uri _resolveUrl(String endpoint) {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    if (base.endsWith('/collector/telemetry')) return Uri.parse(base);
    return Uri.parse('$base/collector/telemetry');
  }

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
      final attrs = crashData['attributes'];
      print('✅ Error report sent successfully');
      if (attrs is Map) {
        print('   📊 Error: ${attrs['message']}');
        if (attrs['crash.source'] != null) {
          print('   🎯 Source: ${attrs['crash.source']}');
        }
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
      final request = await _httpClient.postUrl(_url);
      request.headers.set('Content-Type', 'application/json');
      if (apiKey != null) request.headers.set('X-API-Key', apiKey!);
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
