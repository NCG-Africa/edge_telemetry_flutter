// lib/src/capture/http_url.dart
//
// The URL half of §8's privacy rules (#59). Two pure functions, no state — the
// capture hook picks which one the tier calls for.
//
// `http.request` is the highest-volume event in the system (~40 per typical
// session) and v2 shipped the **full query string** on every one of them,
// eleven lines from the breadcrumb path that strips the query *because* no PII
// should ride the crash ring. The precedent was not missing; it was inverted.

/// The sentinel a templated path segment collapses to. One token for all three
/// id shapes — the backend groups on the templated path, and which *kind* of id
/// it was is not a question anyone asks of a route.
const String kPathIdToken = '{id}';

/// Whether [segment] is an id by the **exact enumerable rule** (#59): all
/// digits, a canonical UUID, or 20+ characters of hex.
///
/// Enumerable is the point. A heuristic ("looks random", entropy over a
/// threshold) cannot be reproduced by a backend reading the rows, so two
/// readers would disagree about what a templated path means. These three
/// shapes cover REST path ids without touching a word like `settings` or a
/// slug like `v2` — and 20 is above every hex-looking short word.
bool isPathId(String segment) {
  if (segment.isEmpty) return false;
  if (_allDigits.hasMatch(segment)) return true;
  if (_uuid.hasMatch(segment)) return true;
  return segment.length >= 20 && _hex.hasMatch(segment);
}

final RegExp _allDigits = RegExp(r'^\d+$');
final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final RegExp _hex = RegExp(r'^[0-9a-fA-F]+$');

/// Replace every id-shaped segment of [path] with [kPathIdToken].
///
/// Its headline job is not PII — an order number is rarely a secret. It is
/// **making the cardinality cap survivable on a REST app**: untemplated, a
/// typical session breaches 50 distinct URLs and `http.url` degrades to a
/// sentinel *after* the real ids already shipped on the first 50 rows, which is
/// the worst of both outcomes.
String templatePath(String path) {
  if (path.isEmpty) return path;
  return path.split('/').map((s) => isPathId(s) ? kPathIdToken : s).join('/');
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
