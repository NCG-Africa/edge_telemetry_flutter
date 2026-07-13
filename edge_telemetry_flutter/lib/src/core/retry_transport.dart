// lib/src/core/retry_transport.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'offline_queue.dart';

/// Low-level POST primitive. Returns true on a 2xx response. Injectable so tests
/// can drive the transport without real network I/O. A `false` return is treated
/// as a reachable HTTP failure (exercises the backoff path); the offline
/// (`status == 0`, immediate-queue) path is only reachable via real HTTP.
typedef Sender = Future<bool> Function(Map<String, dynamic> payload);

/// Backoff schedule for a batch send: attempt, then wait each delay before the
/// next retry, then queue. `[0, 2s, 8s, 30s]` = 4 attempts (family canon).
const List<Duration> kDefaultBackoff = [
  Duration.zero,
  Duration(seconds: 2),
  Duration(seconds: 8),
  Duration(seconds: 30),
];

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
  final List<Duration> backoff;

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
    this.backoff = kDefaultBackoff,
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

  /// Send a batch. Exhaust the [backoff] schedule before giving up; on the last
  /// failure persist the batch verbatim for a later drain. An offline result
  /// (`status == 0`) skips the remaining backoff and queues immediately. On any
  /// success, opportunistically drains the queue.
  Future<bool> send(Map<String, dynamic> batch) async {
    for (var i = 0; i < backoff.length; i++) {
      if (backoff[i] > Duration.zero) await Future.delayed(backoff[i]);
      final status = await _status(batch);
      if (_ok(status)) {
        await drainQueue();
        return true;
      }
      if (status == 0) break; // offline — don't burn backoff, queue now
    }
    await queue.persist(batch);
    return false;
  }

  /// Send a crash immediately, bypassing the batch. On failure, persist to the
  /// offline queue so a crash that kills the app still arrives on next launch.
  Future<void> sendImmediate(Map<String, dynamic> crashData) async {
    final ok = _ok(await _status(crashData));
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
      final filename = await queue.persist(crashData, isCrash: true);
      if (filename != null) {
        print('💾 Error report stored for retry: $filename');
      }
    }
  }

  /// Drain queued payloads through the same POST primitive.
  Future<void> drainQueue() =>
      queue.drain((data) async => _ok(await _status(data)));

  bool _ok(int status) => status >= 200 && status < 300;

  /// One send attempt → HTTP status. Injected [Sender] wins (tests): `true`→200,
  /// `false`→500 (a reachable failure). Real HTTP returns the status, or 0 when
  /// the connection can't be made (offline).
  Future<int> _status(Map<String, dynamic> data) async {
    final sender = _sender;
    if (sender != null) return (await sender(data)) ? 200 : 500;
    return _httpPost(data);
  }

  Future<int> _httpPost(Map<String, dynamic> data) async {
    try {
      final request = await _httpClient.postUrl(_url);
      request.headers.set('Content-Type', 'application/json');
      if (apiKey != null) request.headers.set('X-API-Key', apiKey!);
      request.write(json.encode(data));
      final response = await request.close();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        print('✅ Sent telemetry data successfully');
      } else {
        print('❌ Failed: HTTP ${response.statusCode}');
      }
      return response.statusCode;
    } catch (e) {
      print('❌ Error: $e');
      return 0; // offline / no connection
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
