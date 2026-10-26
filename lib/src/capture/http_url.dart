// lib/src/capture/http_url.dart
//
// The URL half of §8's privacy rules (#59). Two pure functions, no state — the
// capture hook picks which one the tier calls for.
//
// `http.request` is the highest-volume event in the system (~40 per typical
// session) and v2 shipped the **full query string** on every one of them,
// eleven lines from the breadcrumb path that strips the query *because* no PII
// should ride the crash ring. The precedent was not missing; it was inverted.

/// The sentinel a templated path segment collapses to. One token for every
/// id shape — the backend groups on the templated path, and which *kind* of id
/// it was is not a question anyone asks of a route.
const String kPathIdToken = '{id}';

/// Whether [segment] is an id by the RN v4 contract §4.4.1 rule (#125): not a
/// version (`vN`, any case), and either contains a digit or is 32+ chars.
///
/// Verbatim from the sibling, not an illustration — do not "improve" it. The
/// processor re-applies the same rule at ingest, so a divergent rule here would
/// not change a row; it would only let raw ids leave the device.
bool isPathId(String segment) {
  if (_version.hasMatch(segment)) return false;
  if (_digit.hasMatch(segment)) return true;
  return segment.length >= 32;
}

final RegExp _version = RegExp(r'^v\d+$', caseSensitive: false);
final RegExp _digit = RegExp(r'\d');

const int _maxDepth = 6;

/// [path] → route template: id segments become [kPathIdToken], empty segments
/// (trailing or doubled slashes) drop, depth caps at 6 then `/…`, an empty
/// path is `/`. No case folding.
///
/// Its headline job is not PII — an order number is rarely a secret. It is
/// **making the cardinality cap survivable on a REST app**: untemplated, a
/// typical session breaches 50 distinct URLs and `http.url` degrades to a
/// sentinel *after* the real ids already shipped on the first 50 rows, which is
/// the worst of both outcomes.
String templatePath(String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return '/';
  final kept = segments
      .take(_maxDepth)
      .map((s) => isPathId(s) ? kPathIdToken : s);
  final route = '/${kept.join('/')}';
  return segments.length > _maxDepth ? '$route/…' : route;
}

/// The default-tier URL: scheme, host, explicit port, templated path. No query,
/// no fragment, no userinfo.
// ponytail: assembled as a string, not through `Uri()`, which percent-encodes
// the braces (`/users/%7Bid%7D`) and would make the backend group on an
// escaped token nobody writes by hand.
String redactUrl(Uri url) {
  final port = url.hasPort ? ':${url.port}' : '';
  return '${url.scheme}://${url.host}$port${templatePath(url.path)}';
}
