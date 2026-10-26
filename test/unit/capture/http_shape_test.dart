// test/unit/capture/http_shape_test.dart
//
// #85, the shape and privacy halves of §8, asserted on the attribute map that
// actually leaves the device. No sockets here — the seam itself is driven for
// real in http_seam_test.dart.

import 'package:edge_telemetry_flutter/src/capture/http_overrides.dart';
import 'package:edge_telemetry_flutter/src/capture/http_url.dart';
import 'package:flutter_test/flutter_test.dart';

HttpRequestTelemetry _record({
  String url = 'https://api.example.test/v1/users/42?token=secret',
  int statusCode = 200,
  Duration duration = const Duration(milliseconds: 120),
  Duration? download,
  Duration? connect,
  Duration? dns,
  Duration? queue,
  bool? reused,
  int? redirects,
  int? size,
  String? sizeSource,
  String? error,
}) => HttpRequestTelemetry(
  url: url,
  method: 'GET',
  statusCode: statusCode,
  duration: duration,
  timestamp: DateTime.utc(2026, 1, 1),
  downloadDuration: download,
  connectDuration: connect,
  dnsDuration: dns,
  queueDuration: queue,
  connectionReused: reused,
  redirectCount: redirects,
  responseSize: size,
  responseSizeSource: sizeSource,
  error: error,
);

void main() {
  group('path templating — RN contract §4.4.1 (#125)', () {
    test('any digit or 32+ chars is an id; vN is not', () {
      expect(isPathId('42'), isTrue);
      expect(isPathId('3f2504e0-4f89-11d3-9a0c-0305e82c3301'), isTrue);
      expect(isPathId('abc1'), isTrue, reason: 'any digit');
      expect(isPathId('order-7'), isTrue);
      expect(isPathId('a' * 32), isTrue, reason: 'opaque all-alpha token');

      expect(isPathId('v2'), isFalse);
      expect(isPathId('V10'), isFalse, reason: 'carve-out ignores case');
      expect(isPathId('users'), isFalse);
      expect(isPathId('a' * 31), isFalse);
      expect(isPathId('deadbeef'), isFalse, reason: 'no digit, under 32');
    });

    test('templates each id segment and leaves the rest alone', () {
      expect(
        templatePath(
          '/v1/users/42/orders/3f2504e0-4f89-11d3-9a0c-0305e82c3301',
        ),
        '/v1/users/{id}/orders/{id}',
      );
      expect(templatePath('/health'), '/health');
    });

    test(
      'empty → /, trailing and doubled slashes dropped, no case folding',
      () {
        expect(templatePath(''), '/');
        expect(templatePath('/'), '/');
        expect(templatePath('/Users/42/'), '/Users/{id}');
        expect(templatePath('//a//b'), '/a/b');
      },
    );

    test('depth caps at 6 segments, then /…', () {
      expect(templatePath('/a/b/c/d/e/f'), '/a/b/c/d/e/f');
      expect(templatePath('/a/b/c/d/e/f/g/1'), '/a/b/c/d/e/f/…');
    });

    test('the braces survive — no percent-encoding on the wire', () {
      expect(
        redactUrl(Uri.parse('https://a.test/users/42')),
        'https://a.test/users/{id}',
      );
    });
  });

  group('URL policy', () {
    test('default tier is path-only, templated, flagged', () {
      final a = _record().toAttributes();
      expect(a['http.url'], 'https://api.example.test/v1/users/{id}');
      expect(a['http.url_redacted'], 'true');
      expect(a['http.url'], isNot(contains('secret')));
    });

    test('an explicit port survives; userinfo and fragment do not', () {
      final a = _record(url: 'http://u:p@api.test:8443/a#frag').toAttributes();
      expect(a['http.url'], 'http://api.test:8443/a');
    });

    test('diagnostic gets the full URL verbatim and says it is unredacted', () {
      final a = _record().toAttributes(fullUrl: true);
      expect(
        a['http.url'],
        'https://api.example.test/v1/users/42?token=secret',
      );
      expect(a['http.url_redacted'], 'false');
    });
  });

  group('tiers', () {
    test('the default map carries three numbers and no diagnostic phases', () {
      final a =
          _record(
            download: const Duration(milliseconds: 30),
            connect: const Duration(milliseconds: 509),
            dns: const Duration(milliseconds: 40),
            queue: const Duration(milliseconds: 5),
            reused: false,
            redirects: 1,
          ).toAttributes();

      expect(a['http.connect_ms'], '509');
      expect(a['http.download_ms'], '30');
      expect(a['http.connection_reused'], 'false');
      expect(a.keys, isNot(contains('http.dns_ms')));
      expect(a.keys, isNot(contains('http.queue_ms')));
      expect(a.keys, isNot(contains('http.redirect_count')));
    });

    test('diagnostic adds DNS, queue and redirect count', () {
      final a = _record(
        dns: const Duration(milliseconds: 40),
        queue: const Duration(milliseconds: 5),
        redirects: 2,
      ).toAttributes(phases: true);

      expect(a['http.dns_ms'], '40');
      expect(a['http.queue_ms'], '5');
      expect(a['http.redirect_count'], '2');
    });
  });

  group('absence', () {
    test('keys the seam could not reach are omitted, never zeroed', () {
      final a = _record().toAttributes(phases: true);
      for (final key in [
        'http.download_ms',
        'http.connect_ms',
        'http.connection_reused',
        'http.dns_ms',
        'http.queue_ms',
        'http.redirect_count',
        'http.response_size',
        'http.response_size_source',
        'http.error',
      ]) {
        expect(a.keys, isNot(contains(key)), reason: '$key must be absent');
      }
    });

    test('every request names the seam that captured it', () {
      expect(_record().toAttributes()['http.seam'], 'http_overrides');
    });

    test('there is no retry key at either seam', () {
      final a = _record().toAttributes(fullUrl: true, phases: true);
      expect(a.keys.where((k) => k.contains('retry')), isEmpty);
    });
  });

  group('response size', () {
    test('a declared length carries the content-length source', () {
      final a =
          _record(
            size: 1200,
            sizeSource: kSizeFromContentLength,
          ).toAttributes();
      expect(a['http.response_size'], '1200');
      expect(a['http.response_size_source'], 'content_length');
    });

    test('a counted body carries the decoded-bytes source', () {
      final a =
          _record(size: 9000, sizeSource: kSizeFromDecodedBytes).toAttributes();
      expect(a['http.response_size_source'], 'decoded_bytes');
    });
  });

  group('success conforms to 2xx only', () {
    test('2xx is a success, 3xx is not, 4xx/5xx are not', () {
      expect(_record(statusCode: 200).isSuccess, isTrue);
      expect(_record(statusCode: 204).isSuccess, isTrue);
      expect(_record(statusCode: 301).isSuccess, isFalse);
      expect(_record(statusCode: 304).isSuccess, isFalse);
      expect(_record(statusCode: 404).isSuccess, isFalse);
      expect(_record(statusCode: 500).isSuccess, isFalse);
    });

    test('a transport error is never a success whatever the status', () {
      expect(
        _record(statusCode: 200, error: 'SocketException').isSuccess,
        isFalse,
      );
      expect(
        _record(
          statusCode: 0,
          error: 'SocketException',
        ).toAttributes()['http.success'],
        'false',
      );
    });
  });
}
