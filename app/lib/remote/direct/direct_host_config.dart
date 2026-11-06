import 'dart:convert';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';

/// One saved direct host: a DSH server already published over HTTPS (typically
/// `dsh web` behind an nginx reverse proxy) reached by its base URL and an
/// access token.
///
/// This is the deployment where the person needs neither SSH access nor a DSH
/// Remote account: paste `https://dsh.example.com` and the token, and the phone
/// talks to the engine through the proxy. Secrets never live in this object;
/// the token and the session cookie it mints are kept in the [SecretStore].
class DirectHostConfig {
  const DirectHostConfig({required this.id, required this.name, required this.baseUrl});

  /// Stable id (`direct-<hex>`); also the secret-store namespace.
  final String id;

  /// What the person calls it ("家里的电脑", "公司服务器").
  final String name;

  /// Normalized base URL without a path or trailing slash, as returned by
  /// [parseDirectBaseUrl].
  final String baseUrl;

  Uri get baseUri => Uri.parse(baseUrl);

  /// Stable id (`direct-<hex>`); also the secret-store namespace.
  static String newId([math.Random? random]) {
    final r = random ?? math.Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'direct-$hex';
  }

  DirectHostConfig copyWith({String? name, String? baseUrl}) => DirectHostConfig(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
  );

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'baseUrl': baseUrl};

  static DirectHostConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final url = raw['baseUrl'];
    if (id is! String || id.isEmpty || url is! String) return null;
    final base = parseDirectBaseUrl(url);
    if (base == null) return null;
    final name = raw['name'];
    return DirectHostConfig(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name.trim() : base.host,
      baseUrl: base.toString(),
    );
  }

  @override
  bool operator ==(Object other) => other is DirectHostConfig && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'DirectHostConfig($id, $baseUrl)';
}

/// Secrets for one direct host.
class DirectSecrets {
  const DirectSecrets({this.token = '', this.cookie});

  /// The access token the person typed. `dsh web` rotates its launch token on
  /// every start, so a stale token only matters until a cookie is minted.
  final String token;

  /// The signed session cookie the token minted (30 days, bound to the
  /// authority the login used). Present while the link can resume without a
  /// fresh token.
  final DshCookie? cookie;

  bool get hasToken => token.trim().isNotEmpty;

  /// Whether the host can be opened at all: a cookie can resume an existing
  /// session, a token can mint a new one.
  bool get canConnect => cookie != null || hasToken;

  DirectSecrets withCookie(DshCookie? value) => DirectSecrets(token: token, cookie: value);
}

/// Secret-store keys. Namespaced under `direct.` so they never collide with the
/// SSH and relay secrets that share the same store.
abstract final class DirectSecretKeys {
  static String token(String id) => 'direct.$id.token';
  static String cookie(String id) => 'direct.$id.cookie';
}

/// Reads the base URL a person typed, or null when it cannot be one.
///
/// `dsh web` is published at the root of its domain (nginx `location /`), so a
/// subpath is rejected instead of silently breaking every `/api` call. `http://`
/// stays allowed for a LAN address the person reaches directly; the form warns
/// on it rather than blocking it, matching the SSH host rules.
Uri? parseDirectBaseUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  // The doc's "支持 https:// 或 wss://" hint: a WebSocket URL is just the same
  // origin over the plain scheme.
  text = text.replaceFirst(RegExp(r'^wss://', caseSensitive: false), 'https://');
  text = text.replaceFirst(RegExp(r'^ws://', caseSensitive: false), 'http://');

  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (!_isUsableHost(uri.host)) return null;
  if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) return null;
  if (uri.path.isNotEmpty && uri.path != '/') return null;
  return uri.replace(path: '', query: null, fragment: null);
}

/// A hostname, IPv4 literal or IPv6 literal — not whatever [Uri] managed to
/// percent-encode. `dsh example.com` parses as `dsh%20example.com`, which would
/// otherwise be saved and only fail later as "unreachable".
bool _isUsableHost(String host) {
  if (host.isEmpty || host.length > 253) return false;
  if (host.contains('%') || host.contains(' ')) return false;
  // IPv6 literals come back without brackets and contain colons.
  if (host.contains(':')) return RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(host);
  final label = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');
  final labels = host.split('.');
  if (labels.any((part) => !label.hasMatch(part))) return false;
  // A single-label host is a LAN name; allow it, but not a bare digit run that
  // is really a broken IPv4 with an empty label.
  return true;
}

/// Cookie JSON for the secret store; null when absent or unreadable.
DshCookie? decodeDirectCookie(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final map = jsonDecode(raw);
    if (map is! Map) return null;
    final cookie = DshCookie.fromJson(map.cast<String, Object?>());
    return cookie.value.isEmpty ? null : cookie;
  } catch (_) {
    return null;
  }
}

String encodeDirectCookie(DshCookie cookie) => jsonEncode(cookie.toJson());