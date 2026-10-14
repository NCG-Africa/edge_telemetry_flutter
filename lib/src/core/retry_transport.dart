// lib/src/core/retry_transport.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

/// The longest `Retry-After` a batch send will wait out in memory — the
/// schedule's own longest step. A collector asking for longer gets the batch
/// queued now, to go out on a later drain.
final Duration kMaxRetryAfter = kDefaultBackoff.last;

/// One POST's outcome: the HTTP status (0 = unreachable) and the collector's
/// `Retry-After`, when it sent one as delta-seconds.
typedef _Reply = ({int status, Duration? retryAfter});

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

  /// The schedule a transport gets when none is passed. Mutable for tests that
  /// drive the real `initialize()` and can't wait 40 s per failed batch.
  @visibleForTesting
  static List<Duration> defaultBackoff = kDefaultBackoff;

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

  /// The POST target: [endpoint] exactly as configured (R10). Nothing is
  /// appended — the consumer names the full collector route.
  final Uri _url;

  RetryTransport({
    required this.endpoint,
    required this.queue,
    this.apiKey,
    this.debugMode = false,
    List<Duration>? backoff,
    this.onDrop,
    HttpClient? httpClient,
    Sender? sender,
  }) : backoff = backoff ?? defaultBackoff,
       _httpClient = httpClient ?? HttpClient(),
       _sender = sender,
       _url = Uri.parse(endpoint);

  /// The POST target. Read by the HTTP capture hook to exclude the SDK's own
  /// upload **explicitly** rather than by construction order.
  Uri get resolvedUrl => _url;

  /// Send a batch. Exhaust the [backoff] schedule before giving up; on the last
  /// failure persist the batch verbatim for a later drain. An offline result
  /// (`status == 0`) skips the remaining backoff and queues immediately. A
  /// `Retry-After` stretches the next wait to at least what the collector
  /// asked for, up to [kMaxRetryAfter]; beyond that the batch queues now. On
  /// any success, opportunistically drains the queue.
  Future<bool> send(Map<String, dynamic> batch) async {
    var asked = Duration.zero;
    for (var i = 0; i < backoff.length; i++) {
      final wait = backoff[i] > asked ? backoff[i] : asked;
      if (wait > Duration.zero) await Future.delayed(wait);
      final (:status, :retryAfter) = await _attempt(batch);
      if (_ok(status)) {
        await drainQueue();
        return true;
      }
      // 4xx (not 429): never retried, never queued.
      if (_clientError(status)) return _countDrop(status);
      if (status == 0) break; // offline — don't burn backoff, queue now
      asked = retryAfter ?? Duration.zero;
      if (asked > kMaxRetryAfter) break; // longer than we hold a batch: queue
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
    final (:status, retryAfter: _) = await _attempt(crashBatch);
    final item = (crashBatch['events'] as List?)?.firstOrNull;
    if (_ok(status)) {
      // The one-line outcome is intentionally always printed; anything naming
      // the error, the user or the session is debugMode only (SDK-003, #120).
      print('✅ Error report sent successfully');
      final attrs = item is Map ? item['attributes'] : null;
      if (debugMode && attrs is Map) {
        print('   📊 Error: ${attrs['message']}');
        if (attrs['crash.source'] != null) {
          print('   🎯 Source: ${attrs['crash.source']}');
        }
        if (attrs['user.id'] != null) print('   👤 User: ${attrs['user.id']}');
        if (attrs['session.id'] != null) {
          print('   🔄 Session: ${attrs['session.id']}');
        }
      }
      if (debugMode) print('   ⏰ Timestamp: ${crashBatch['timestamp']}');
      await drainQueue();
    } else if (_clientError(status)) {
      // A payload the collector rejects outright will never be accepted; storing
      // it only buys an unbounded re-POST on every later success.
      print('❌ Error report rejected (HTTP $status), dropped');
      _countDrop(status);
    } else {
      print('❌ Failed to send error report, storing offline');
      final filename = await queue.persist(crashBatch, isCrash: true);
      if (debugMode && filename != null) {
        print('💾 Error report stored for retry: $filename');
      }
    }
  }

  /// Drain queued payloads through the same POST primitive. A payload stored
  /// before the immediate rail was enveloped is re-wrapped on the way out, which
  /// is what makes the crash backlog accumulated since v2.0.0 deliverable.
  ///
  /// A 4xx other than 429 counts as *done with this file*: it is dropped, not retried. An
  /// offline result teaches nothing about the payload, so it abandons the cycle
  /// rather than spending every queued file's attempt allowance on the weather.
  /// A `Retry-After` also ends the cycle — the collector asked us to wait, so
  /// the files behind this one are not POSTed into the same refusal.
  Future<void> drainQueue() => queue.drain((stored) async {
    final (:status, :retryAfter) = await _attempt(rewrapIfBare(stored));
    if (_ok(status)) return DrainResult.done;
    if (_clientError(status)) {
      _countDrop(status);
      return DrainResult.done; // refused outright — stop retrying it
    }
    if (status == 0) return DrainResult.offline;
    return retryAfter != null ? DrainResult.deferred : DrainResult.failed;
  });

  bool _ok(int status) => status >= 200 && status < 300;

  /// 4xx: the collector understood the request and refuses it. Retrying or
  /// queueing it re-POSTs the same rejection forever (the v2 amplification).
  /// Except 429, which is "not now", not "never": retried like a 5xx (R12).
  bool _clientError(int status) =>
      status >= 400 && status < 500 && status != 429;

  /// Record a payload the transport refused to retry. Returns false so the
  /// batch path can `return _countDrop(status)` — a drop is always a failed send.
  bool _countDrop(int status) {
    onDrop?.call('http_$status');
    if (debugMode) print('🚫 Dropped payload — HTTP $status, not retryable');
    return false;
  }

  /// One send attempt → the collector's reply. Injected [Sender] wins (tests): `true`→200,
  /// `false`→500 (a reachable failure). Real HTTP returns the status, or 0 when
  /// the connection can't be made (offline).
  Future<_Reply> _attempt(Map<String, dynamic> data) async {
    stampForSend(data);
    final sender = _sender;
    if (sender != null) {
      return (status: (await sender(data)) ? 200 : 500, retryAfter: null);
    }
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
  Future<_Reply> _httpPost(Map<String, dynamic> data) async {
    final body = utf8.encode(json.encode(data));

    var reply = await _post(body, gzip: _compress);
    if (reply.status == 400 && _compress && !_probeSpent) {
      // ponytail: one probe per launch, even when the plain retry also fails.
      // A 400 on both means the payload was bad, not the encoding — so gzip
      // stays on. The residual: if that first 400 is a bad payload *and* the
      // collector also cannot decompress, the launch drops everything and
      // re-probes on the next one. Spend a second probe on a later 400 if that
      // shows up in the field; the issue's ceiling is one wasted POST.
      _probeSpent = true;
      reply = await _post(body, gzip: false);
      if (_ok(reply.status)) {
        _compress = false;
        if (debugMode) print('🗜️ gzip not accepted — sending uncompressed');
      }
    }

    if (_ok(reply.status)) {
      print('✅ Sent telemetry data successfully');
    } else {
      print('❌ Failed: HTTP ${reply.status}');
    }
    return reply;
  }

  Future<_Reply> _post(List<int> body, {required bool gzip}) async {
    try {
      final request = await _httpClient.postUrl(_url);
      request.headers.set('Content-Type', 'application/json');
      if (apiKey != null) request.headers.set('X-API-Key', apiKey!);
      if (gzip) request.headers.set('Content-Encoding', 'gzip');
      request.add(gzip ? GZipCodec().encode(body) : body);
      final response = await request.close();
      await response.drain<void>();
      // ponytail: delta-seconds only; an HTTP-date Retry-After is ignored
      // (the collector sends seconds). Parse dates if another server needs it.
      final seconds = int.tryParse(
        response.headers.value(HttpHeaders.retryAfterHeader)?.trim() ?? '',
      );
      return (
        status: response.statusCode,
        retryAfter:
            seconds == null || seconds <= 0 ? null : Duration(seconds: seconds),
      );
    } catch (e) {
      if (debugMode) print('❌ Error: $e');
      return (status: 0, retryAfter: null); // offline / no connection
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
