// lib/src/core/retry_transport.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'clock_skew.dart';
import 'offline_queue.dart';
import 'wire_canon.dart';

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
  /// Process-wide compression state. Static on purpose: "at most one wasted POST
  /// per launch" is a property of the launch, not of a transport instance.
  static bool _compress = true;
  static bool _probeSpent = false;

  /// Reset the launch-scoped gzip probe (tests only).
  @visibleForTesting
  static void resetGzipProbe() {
    _compress = true;
    _probeSpent = false;
  }

  final String endpoint;
  final String? apiKey;
  final OfflineQueue queue;
  final bool debugMode;
  final List<Duration> backoff;

  /// Counts a payload the transport refused to retry, by short stable reason
  /// slug (`http_400`, …) — the same counter the off-canon drop uses.
  final void Function(String reason)? onDrop;

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
    this.onDrop,
    HttpClient? httpClient,
    Sender? sender,
  }) : _httpClient = httpClient ?? HttpClient(),
       _sender = sender,
       _url = _resolveUrl(endpoint);

  /// The resolved POST target. Read by the HTTP capture hook to exclude the
  /// SDK's own upload **explicitly** rather than by construction order.
  Uri get resolvedUrl => _url;

  static Uri _resolveUrl(String endpoint) {
    final base =
        endpoint.endsWith('/')
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
      // 4xx: never retried, never queued.
      if (_clientError(status)) return _countDrop(status);
      if (status == 0) break; // offline — don't burn backoff, queue now
    }
    await queue.persist(batch);
    return false;
  }

  /// Send a crash immediately, bypassing the batch. On failure, persist to the
  /// offline queue so a crash that kills the app still arrives on next launch.
  /// [crashBatch] is an assembled one-item `telemetry_batch` envelope — the
  /// queue stores bytes verbatim, so what is persisted here must already be a
  /// payload the collector will accept whenever it is drained.
  Future<void> sendImmediate(Map<String, dynamic> crashBatch) async {
    final status = await _status(crashBatch);
    final item = (crashBatch['events'] as List?)?.firstOrNull;
    if (_ok(status)) {
      // Error-report send logs are intentionally always printed (see CLAUDE.md).
      final attrs = item is Map ? item['attributes'] : null;
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
      print('   ⏰ Timestamp: ${crashBatch['timestamp']}');
      await drainQueue();
    } else if (_clientError(status)) {
      // A payload the collector rejects outright will never be accepted; storing
      // it only buys an unbounded re-POST on every later success.
      print('❌ Error report rejected (HTTP $status), dropped');
      _countDrop(status);
    } else {
      print('❌ Failed to send error report, storing offline');
      final filename = await queue.persist(crashBatch, isCrash: true);
      if (filename != null) {
        print('💾 Error report stored for retry: $filename');
      }
    }
  }

  /// Drain queued payloads through the same POST primitive. A payload stored
  /// before the immediate rail was enveloped is re-wrapped on the way out, which
  /// is what makes the crash backlog accumulated since v2.0.0 deliverable.
  ///
  /// A 4xx counts as *done with this file*: it is dropped, not retried. An
  /// offline result teaches nothing about the payload, so it abandons the cycle
  /// rather than spending every queued file's attempt allowance on the weather.
  Future<void> drainQueue() => queue.drain((stored) async {
    final status = await _status(rewrapIfBare(stored));
    if (_ok(status)) return DrainResult.done;
    if (_clientError(status)) {
      _countDrop(status);
      return DrainResult.done; // refused outright — stop retrying it
    }
    return status == 0 ? DrainResult.offline : DrainResult.failed;
  });

  bool _ok(int status) => status >= 200 && status < 300;

  /// 4xx: the collector understood the request and refuses it. Retrying or
  /// queueing it re-POSTs the same rejection forever (the v2 amplification).
  bool _clientError(int status) => status >= 400 && status < 500;

  /// Record a payload the transport refused to retry. Returns false so the
  /// batch path can `return _countDrop(status)` — a drop is always a failed send.
  bool _countDrop(int status) {
    onDrop?.call('http_$status');
    if (debugMode) print('🚫 Dropped payload — HTTP $status, not retryable');
    return false;
  }

  /// One send attempt → HTTP status. Injected [Sender] wins (tests): `true`→200,
  /// `false`→500 (a reachable failure). Real HTTP returns the status, or 0 when
  /// the connection can't be made (offline).
  Future<int> _status(Map<String, dynamic> data) async {
    final sender = _sender;
    if (sender != null) return (await sender(data)) ? 200 : 500;
    return _httpPost(data);
  }

  /// POST [data], gzipped unless the launch has already downgraded.
  ///
  /// The downgrade is self-verifying and costs at most one wasted POST per
  /// launch: a 400 on a compressed body *might* mean the collector can't
  /// decompress, so re-POST the same bytes uncompressed exactly once. If that
  /// succeeds, the 400 was about the encoding and compression stays off for the
  /// launch; if it fails too, the payload was simply bad and the probe is spent
  /// either way. No config flag and no version endpoint — the probe *is* the
  /// capability check.
  Future<int> _httpPost(Map<String, dynamic> data) async {
    final body = utf8.encode(json.encode(data));

    var status = await _post(body, gzip: _compress);
    if (status == 400 && _compress && !_probeSpent) {
      // ponytail: one probe per launch, even when the plain retry also fails.
      // A 400 on both means the payload was bad, not the encoding — so gzip
      // stays on. The residual: if that first 400 is a bad payload *and* the
      // collector also cannot decompress, the launch drops everything and
      // re-probes on the next one. Spend a second probe on a later 400 if that
      // shows up in the field; the issue's ceiling is one wasted POST.
      _probeSpent = true;
      final plain = await _post(body, gzip: false);
      if (_ok(plain)) {
        _compress = false;
        if (debugMode) print('🗜️ gzip not accepted — sending uncompressed');
      }
      status = plain;
    }

    if (_ok(status)) {
      print('✅ Sent telemetry data successfully');
    } else {
      print('❌ Failed: HTTP $status');
    }
    return status;
  }

  Future<int> _post(List<int> body, {required bool gzip}) async {
    try {
      final request = await _httpClient.postUrl(_url);
      request.headers.set('Content-Type', 'application/json');
      if (apiKey != null) request.headers.set('X-API-Key', apiKey!);
      if (gzip) request.headers.set('Content-Encoding', 'gzip');
      request.add(gzip ? GZipCodec().encode(body) : body);
      final response = await request.close();
      await response.drain<void>();
      // Free server time on a response we already have. Recorded, not applied,
      // and only from a POST the collector accepted — a 4xx can come from an
      // edge that never reached it, so its `Date` is a different clock.
      if (_ok(response.statusCode)) recordClockSkew(response.headers.date);
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
