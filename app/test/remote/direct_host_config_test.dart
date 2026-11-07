// Direct host config: URL normalization, JSON round trips, secret-store keys
// and the session-cookie encoding used to persist a login without the token.

import 'dart:math' as math;

import 'package:dsh_app/remote/direct/direct_host_config.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _cookie = DshCookie(
  name: 'dsh-auth-abc',
  value: 'v1.payload.signature',
  authority: 'dsh.example.com',
);

void main() {
  group('parseDirectBaseUrl', () {
    test('a bare host is reached over https', () {
      expect(parseDirectBaseUrl('dsh.example.com'), Uri.parse('https://dsh.example.com'));
    });

    test('http is kept for a LAN address reached directly', () {
      expect(parseDirectBaseUrl('http://192.168.1.5:8080'), Uri.parse('http://192.168.1.5:8080'));
    });

    test('a WebSocket URL becomes its HTTP origin', () {
      expect(parseDirectBaseUrl('wss://dsh.example.com'), Uri.parse('https://dsh.example.com'));
      expect(parseDirectBaseUrl('ws://dsh.example.com'), Uri.parse('http://dsh.example.com'));
      expect(parseDirectBaseUrl('WSS://dsh.example.com'), Uri.parse('https://dsh.example.com'));
    });

    test('a trailing slash is dropped', () {
      expect(parseDirectBaseUrl('https://dsh.example.com/'), Uri.parse('https://dsh.example.com'));
    });

    test('a subpath is rejected instead of breaking every API call', () {
      expect(parseDirectBaseUrl('https://dsh.example.com/dsh'), isNull, reason: 'dsh web lives at /');
      expect(parseDirectBaseUrl('https://dsh.example.com/api/'), isNull);
    });

    test('query, fragment and user info are rejected', () {
      for (final raw in [
        'https://dsh.example.com?token=x',
        'https://dsh.example.com/?token=x',
        'https://dsh.example.com#fragment',
        'https://user:pw@dsh.example.com',
      ]) {
        expect(parseDirectBaseUrl(raw), isNull, reason: raw);
      }
    });

    test('empty or unparsable input is rejected', () {
      for (final raw in ['', '   ', 'https://', 'https:///path', 'http://[::1']) {
        expect(parseDirectBaseUrl(raw), isNull, reason: '"$raw"');
      }
    });

    test('whitespace or markup that Uri can percent-encode is not a hostname', () {
      for (final raw in [
        'not a url',
        'dsh example.com',
        '<script>',
        'https://not%20a%20url',
        'https://dsh%20example.com',
      ]) {
        expect(parseDirectBaseUrl(raw), isNull, reason: '"$raw" must not be saved as a host');
      }
    });

    test('plain hostnames and IP literals still parse', () {
      expect(parseDirectBaseUrl('example.com'), Uri.parse('https://example.com'));
      expect(parseDirectBaseUrl('[::1]'), Uri.parse('https://[::1]'));
      expect(parseDirectBaseUrl('192.168.1.10:8080'), Uri.parse('https://192.168.1.10:8080'));
    });

    test('an unsupported scheme is rejected', () {
      expect(parseDirectBaseUrl('ftp://dsh.example.com'), isNull);
      expect(parseDirectBaseUrl('mailto:me@example.com'), isNull);
    });

    test('a non-default port is kept', () {
      expect(parseDirectBaseUrl('dsh.example.com:8443'), Uri.parse('https://dsh.example.com:8443'));
      expect(parseDirectBaseUrl('http://10.0.0.2:3080'), Uri.parse('http://10.0.0.2:3080'));
    });

    test('an IPv6 host is kept', () {
      expect(parseDirectBaseUrl('[::1]:3080'), Uri.parse('https://[::1]:3080'));
      expect(parseDirectBaseUrl('https://[2001:db8::1]:8443'), Uri.parse('https://[2001:db8::1]:8443'));
    });
  });

  group('DirectHostConfig', () {
    const config = DirectHostConfig(id: 'direct-0123456789abcdef', name: '家里的电脑', baseUrl: 'https://dsh.example.com');

    test('toJson/fromJson round trip keeps id, name and base URL', () {
      final restored = DirectHostConfig.fromJson(config.toJson());
      expect(restored, isNotNull);
      expect(restored!.id, config.id);
      expect(restored.name, config.name);
      expect(restored.baseUrl, config.baseUrl);
      expect(restored, config, reason: 'equality is by stable id');
    });

    test('a missing or blank name falls back to the host', () {
      final noName = DirectHostConfig.fromJson({'id': 'direct-1', 'baseUrl': 'https://dsh.example.com'});
      final blankName = DirectHostConfig.fromJson({'id': 'direct-2', 'name': '   ', 'baseUrl': 'https://dsh.example.com'});
      expect(noName?.name, 'dsh.example.com');
      expect(blankName?.name, 'dsh.example.com');
    });

    test('the saved base URL is normalized and the name trimmed', () {
      final restored = DirectHostConfig.fromJson({
        'id': 'direct-3',
        'name': '  公司服务器  ',
        'baseUrl': 'wss://dsh.example.com/',
      });
      expect(restored?.name, '公司服务器');
      expect(restored?.baseUrl, 'https://dsh.example.com');
    });

    test('an invalid entry decodes to null', () {
      for (final raw in <Object?>[
        null,
        42,
        'direct-1',
        <Object?>[],
        <String, Object?>{},
        <String, Object?>{'id': 'direct-1'},
        <String, Object?>{'id': '', 'baseUrl': 'https://dsh.example.com'},
        <String, Object?>{'id': 'direct-1', 'baseUrl': 42},
        <String, Object?>{'id': 'direct-1', 'baseUrl': 'https://dsh.example.com/dsh'},
        <String, Object?>{'id': 'direct-1', 'baseUrl': 'ftp://dsh.example.com'},
      ]) {
        expect(DirectHostConfig.fromJson(raw), isNull, reason: '$raw');
      }
    });

    test('copyWith renames or re-addresses without losing the id', () {
      final renamed = config.copyWith(name: '公司服务器');
      final moved = config.copyWith(baseUrl: 'https://other.example.com');
      expect(renamed.id, config.id);
      expect(renamed.name, '公司服务器');
      expect(renamed.baseUrl, config.baseUrl);
      expect(moved.id, config.id);
      expect(moved.baseUrl, 'https://other.example.com');
    });

    test('newId is a stable direct- namespace id', () {
      final first = DirectHostConfig.newId(math.Random(1));
      final second = DirectHostConfig.newId(math.Random(2));
      expect(first, matches(RegExp(r'^direct-[0-9a-f]{16}$')));
      expect(second, matches(RegExp(r'^direct-[0-9a-f]{16}$')));
      expect(first, isNot(second));
    });
  });

  group('DirectSecrets', () {
    test('a cookie alone can resume a session; a blank token cannot connect', () {
      expect(const DirectSecrets(cookie: _cookie).canConnect, isTrue);
      expect(const DirectSecrets(token: 'tok').canConnect, isTrue);
      expect(const DirectSecrets(token: '   ').hasToken, isFalse);
      expect(const DirectSecrets(token: '   ').canConnect, isFalse);
      expect(const DirectSecrets().canConnect, isFalse);
    });

    test('withCookie keeps the token', () {
      final secrets = const DirectSecrets(token: 'tok').withCookie(_cookie);
      expect(secrets.token, 'tok');
      expect(secrets.cookie, same(_cookie));
      expect(secrets.withCookie(null).cookie, isNull);
    });
  });

  group('secret-store keys', () {
    test('are namespaced under direct. so they cannot collide with SSH or relay', () {
      expect(DirectSecretKeys.token('direct-1'), 'direct.direct-1.token');
      expect(DirectSecretKeys.cookie('direct-1'), 'direct.direct-1.cookie');
    });
  });

  group('session cookie encoding', () {
    test('encode/decode round trip keeps every field', () {
      final withExpiry = DshCookie(
        name: _cookie.name,
        value: _cookie.value,
        authority: _cookie.authority,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(1767225600000, isUtc: true),
      );
      final decoded = decodeDirectCookie(encodeDirectCookie(withExpiry));
      expect(decoded, isNotNull);
      expect(decoded!.name, withExpiry.name);
      expect(decoded.value, withExpiry.value);
      expect(decoded.authority, withExpiry.authority);
      expect(decoded.expiresAt?.millisecondsSinceEpoch, withExpiry.expiresAt?.millisecondsSinceEpoch);
    });

    test('absent or unreadable cookie JSON decodes to null', () {
      for (final raw in <String?>[
        null,
        '',
        'not json',
        '[]',
        '{}',
        '{"name":"dsh-auth-abc","authority":"dsh.example.com"}',
        '{"name":"dsh-auth-abc","value":"","authority":"dsh.example.com"}',
        '{"name":1,"value":2,"authority":3}',
      ]) {
        expect(decodeDirectCookie(raw), isNull, reason: '$raw');
      }
    });
  });
}