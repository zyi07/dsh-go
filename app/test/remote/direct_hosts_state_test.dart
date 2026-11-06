// Direct hosts in state: configs in SharedPreferences, token/cookie only in
// the secret store, reload across containers, and removal switching back home.

import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = DirectHostConfig(
  id: 'direct-0123456789abcdef',
  name: '实验室服务器',
  baseUrl: 'https://dsh.example.com',
);

const _cookie = DshCookie(
  name: 'dsh-auth-lab',
  value: 'v1.payload.signature',
  authority: 'dsh.example.com',
);

class _BrokenSecrets extends MemorySecretStore {
  @override
  Future<String?> read(String key) async => throw StateError('secret store unavailable');

  @override
  Future<void> write(String key, String value) async => throw StateError('secret store unavailable');

  @override
  Future<void> delete(String key) async => throw StateError('secret store unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySecretStore secrets;

  ProviderContainer container([SecretStore? store]) {
    final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(store ?? secrets)]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> loaded(ProviderContainer c) async {
    await c.read(hostsProvider.notifier).ready;
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySecretStore();
  });

  group('HostRef.direct', () {
    test('round-trips through encode/decode and keeps its display name', () {
      const ref = HostRef.direct('direct-0123456789abcdef', name: '家里的电脑');
      final decoded = HostRef.decode(ref.encode());
      expect(decoded, ref, reason: 'equality only needs kind + id');
      expect(decoded.kind, HostKind.direct);
      expect(decoded.id, ref.id);
      expect(decoded.name, '家里的电脑');
      expect(ref, isNot(const HostRef.ssh('direct-0123456789abcdef')));
    });

    test('an entry without a name still decodes as a direct host', () {
      final decoded = HostRef.decode('{"kind":"direct","id":"direct-1"}');
      expect(decoded.kind, HostKind.direct);
      expect(decoded.name, isNull);
    });
  });

  group('HostsController direct hosts', () {
    test('persists the config to preferences and the token/cookie only to the secret store', () async {
      final c = container();
      await loaded(c);

      final saved = await c
          .read(hostsProvider.notifier)
          .saveDirect(_config, secrets: const DirectSecrets(token: 'tok-abc', cookie: _cookie));

      expect(saved, isTrue, reason: 'the preferences write must succeed');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(HostsController.directPrefsKey)!;
      expect(raw, contains(_config.id));
      expect(raw, contains('https://dsh.example.com'));
      expect(raw, isNot(contains('tok-abc')), reason: 'access tokens never go to preferences');
      expect(raw, isNot(contains(_cookie.value)), reason: 'session cookies never go to preferences');
      expect(secrets.values[DirectSecretKeys.token(_config.id)], 'tok-abc');
      expect(decodeDirectCookie(secrets.values[DirectSecretKeys.cookie(_config.id)])?.value, _cookie.value);

      final state = c.read(hostsProvider);
      expect(state.direct, hasLength(1));
      expect(state.directById(_config.id)?.name, '实验室服务器');
    });

    test('a fresh container reads the saved host and its secrets back', () async {
      final first = container();
      await loaded(first);
      await first
          .read(hostsProvider.notifier)
          .saveDirect(_config, secrets: const DirectSecrets(token: 'tok-abc', cookie: _cookie));

      final second = container();
      await loaded(second);

      final restored = second.read(hostsProvider).direct.single;
      expect(restored.id, _config.id);
      expect(restored.name, _config.name);
      expect(restored.baseUrl, _config.baseUrl);
      final secretsBack = await second.read(hostsProvider.notifier).loadDirectSecrets(_config.id);
      expect(secretsBack.token, 'tok-abc');
      expect(secretsBack.cookie?.name, _cookie.name);
      expect(secretsBack.cookie?.value, _cookie.value);
      expect(secretsBack.cookie?.authority, _cookie.authority);
    });

    test('saving the same id replaces the host instead of duplicating it', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);

      await hosts.saveDirect(_config);
      await hosts.saveDirect(_config.copyWith(name: '公司服务器', baseUrl: 'https://other.example.com'));

      final state = c.read(hostsProvider);
      expect(state.direct, hasLength(1));
      expect(state.directById(_config.id)?.name, '公司服务器');
      expect(state.directById(_config.id)?.baseUrl, 'https://other.example.com');
    });

    test('saving with an empty token/cookie clears the stored credentials', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveDirect(_config, secrets: const DirectSecrets(token: 'tok-abc', cookie: _cookie));

      await hosts.saveDirect(_config.copyWith(name: '换了名字'), secrets: const DirectSecrets());

      expect(secrets.values.containsKey(DirectSecretKeys.token(_config.id)), isFalse);
      expect(secrets.values.containsKey(DirectSecretKeys.cookie(_config.id)), isFalse);
    });

    test('loadDirectSecrets for an unknown host is empty', () async {
      final c = container();
      await loaded(c);

      final missing = await c.read(hostsProvider.notifier).loadDirectSecrets('direct-does-not-exist');

      expect(missing.token, '');
      expect(missing.cookie, isNull);
      expect(missing.canConnect, isFalse);
    });

    test('saveDirectCookie stores a minted cookie that the next start reads back', () async {
      final c = container();
      await loaded(c);

      await c.read(hostsProvider.notifier).saveDirectCookie(_config.id, _cookie);
      final loadedSecrets = await c.read(hostsProvider.notifier).loadDirectSecrets(_config.id);

      expect(loadedSecrets.token, '');
      expect(loadedSecrets.cookie?.value, _cookie.value);
      expect(loadedSecrets.canConnect, isTrue, reason: 'the cookie resumes the session without a token');
    });

    test('removeDirect drops the host, its token and cookie, and switches back to 本机', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveDirect(_config, secrets: const DirectSecrets(token: 'tok-abc', cookie: _cookie));
      c.read(activeHostProvider.notifier).select(HostRef.direct(_config.id, name: '实验室服务器'));
      expect(c.read(activeHostProvider), HostRef.direct(_config.id));

      await hosts.removeDirect(_config.id);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(hostsProvider).direct, isEmpty);
      expect(c.read(activeHostProvider), HostRef.local);
      expect(secrets.values, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(HostsController.directPrefsKey), isNot(contains(_config.id)));
    });

    test('a corrupt entry is dropped but the valid direct hosts still load', () async {
      SharedPreferences.setMockInitialValues({
        HostsController.directPrefsKey: jsonEncode([
          _config.toJson(),
          {'id': 'direct-no-url'},
          42,
          {'id': 'direct-subpath', 'baseUrl': 'https://dsh.example.com/dsh'},
          {'id': 'direct-other', 'baseUrl': 'https://other.example.com'},
        ]),
      });
      final c = container();
      await loaded(c);

      expect(c.read(hostsProvider).direct.map((host) => host.id), [_config.id, 'direct-other']);
    });

    test('unreadable direct-host preferences start from an empty list', () async {
      SharedPreferences.setMockInitialValues({HostsController.directPrefsKey: 'not json'});
      final c = container();
      await loaded(c);

      expect(c.read(hostsProvider).direct, isEmpty);
    });

    test('an unavailable secret store still saves the host and reads as empty secrets', () async {
      final c = container(_BrokenSecrets());
      await loaded(c);

      expect(await c.read(hostsProvider.notifier).saveDirect(_config), isTrue);
      final loadedSecrets = await c.read(hostsProvider.notifier).loadDirectSecrets(_config.id);
      expect(loadedSecrets.token, '');
      expect(loadedSecrets.cookie, isNull);
      await c.read(hostsProvider.notifier).saveDirectCookie(_config.id, _cookie);
      expect(c.read(hostsProvider).direct, hasLength(1));
    });
  });
}