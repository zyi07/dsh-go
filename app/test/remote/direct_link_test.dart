// Direct host link: stored cookie first, token fallback on 401, minted cookie
// persistence, bounded reconnect, and the one-shot "测试连接" probe.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/direct/direct_host_config.dart';
import 'package:dsh_app/remote/direct/direct_link.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = 'https://dsh.example.com';

const _storedCookie = DshCookie(
  name: 'dsh-auth-stored',
  value: 'v1.stored.signature',
  authority: 'dsh.example.com',
);

const _mintedCookie = DshCookie(
  name: 'dsh-auth-minted',
  value: 'v1.minted.signature',
  authority: 'dsh.example.com',
);

Uri get _baseUri => Uri.parse(_base);

/// A real HTTP-carrier client that never touches the network: the connection
/// is constructed but nothing is sent, and [close] only tears down local state.
/// Passing [cookie] models a client whose login already minted that cookie,
/// which is what [DirectHostLink] persists.
class _FakeClient extends DshClient {
  _FakeClient({DshCookie? cookie}) : super(DshConnection(_baseUri, cookie: cookie));

  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

class _OpenCall {
  _OpenCall({required this.baseUri, this.token, this.cookie});

  final Uri baseUri;
  final String? token;
  final DshCookie? cookie;
}

/// Records every open and replays [script] in order: a [DshClient] resolves it,
/// anything else is thrown.
class _Opener {
  _Opener(this.script);

  final List<Object> script;
  final List<_OpenCall> calls = [];

  Future<DshClient> call({required Uri baseUri, String? token, DshCookie? cookie}) async {
    calls.add(_OpenCall(baseUri: baseUri, token: token, cookie: cookie));
    if (script.isEmpty) throw StateError('unexpected open: no scripted result left');
    final next = script.removeAt(0);
    if (next is DshClient) return next;
    throw next;
  }
}

Matcher _hostLinkError(HostLinkErrorKind kind) =>
    isA<HostLinkError>().having((error) => error.kind, 'kind', kind);

void main() {
  group('DirectHostLink', () {
    test('a stored cookie opens the host without spending the token, and connects', () async {
      final phases = <HostLinkPhase>[];
      final opener = _Opener([_FakeClient(cookie: _storedCookie)]);
      final link = DirectHostLink(
        baseUri: _baseUri,
        loadSecrets: () async => const DirectSecrets(cookie: _storedCookie),
        saveCookie: (_) async {},
        open: opener.call,
      );
      addTearDown(link.close);
      link.statuses.listen((status) => phases.add(status.phase));

      final client = await link.open();

      expect(opener.calls, hasLength(1), reason: 'the stored cookie is tried first');
      expect(opener.calls.single.baseUri, _baseUri);
      expect(opener.calls.single.cookie, same(_storedCookie));
      expect(opener.calls.single.token, isNull, reason: 'a stored cookie must not spend the token');
      expect(link.status.phase, HostLinkPhase.connected);
      expect(link.currentClient, same(client));
      expect(phases, [HostLinkPhase.connecting, HostLinkPhase.connected]);
    });

    test('without a cookie it logs in with the token and saves the minted cookie', () async {
      final saved = <DshCookie>[];
      final opener = _Opener([_FakeClient(cookie: _mintedCookie)]);
      final link = DirectHostLink(
        baseUri: _baseUri,
        loadSecrets: () async => const DirectSecrets(token: 'tok-1'),
        saveCookie: (cookie) async => saved.add(cookie),
        open: opener.call,
      );
      addTearDown(link.close);

      await link.open();
      await pumpEventQueue();

      expect(opener.calls.single.token, 'tok-1');
      expect(opener.calls.single.cookie, isNull);
      expect(saved, hasLength(1), reason: 'the cookie keeps the next start off the rotating token');
      expect(saved.single, same(_mintedCookie));
      expect(link.status.phase, HostLinkPhase.connected);
    });

    test('an expired cookie falls back to the token and connects', () async {
      final saved = <DshCookie>[];
      final opener = _Opener([
        const DshHttpException(401, 'expired cookie'),
        _FakeClient(cookie: _mintedCookie),
      ]);
      final link = DirectHostLink(
        baseUri: _baseUri,
        loadSecrets: () async => const DirectSecrets(token: 'tok-2', cookie: _storedCookie),
        saveCookie: (cookie) async => saved.add(cookie),
        open: opener.call,
      );
      addTearDown(link.close);

      await link.open();
      await pumpEventQueue();

      expect(opener.calls, hasLength(2), reason: 'cookie first, then the token');
      expect(opener.calls.first.cookie, same(_storedCookie));
      expect(opener.calls.first.token, isNull);
      expect(opener.calls.last.token, 'tok-2');
      expect(opener.calls.last.cookie, isNull);
      expect(link.status.phase, HostLinkPhase.connected);
      expect(saved.single, same(_mintedCookie), reason: 'the cookie minted by the token login is stored');
    });

    test('an expired cookie without a token fails and asks the person to sign in again', () async {
      final opener = _Opener([const DshHttpException(401, 'expired cookie')]);
      final link = DirectHostLink(
        baseUri: _baseUri,
        loadSecrets: () async => const DirectSecrets(cookie: _storedCookie),
        saveCookie: (_) async {},
        open: opener.call,
      );
      addTearDown(link.close);

      await expectLater(link.open(), throwsA(_hostLinkError(HostLinkErrorKind.authFailed)));
      expect(link.status.phase, HostLinkPhase.failed);
      expect(link.status.error?.message, appL10n.remoteErrDshSignInExpired);
      expect(link.currentClient, isNull);
      expect(opener.calls, hasLength(1), reason: 'no token means there is nothing to retry with');

      await link.close();
    });

    test('without a token or cookie it fails before opening anything', () async {
      final opener = _Opener([]);
      final link = DirectHostLink(
        baseUri: _baseUri,
        loadSecrets: () async => const DirectSecrets(),
        saveCookie: (_) async {},
        open: opener.call,
      );
      addTearDown(link.close);

      await expectLater(link.open(), throwsA(_hostLinkError(HostLinkErrorKind.authFailed)));
      expect(link.status.phase, HostLinkPhase.failed);
      expect(link.status.error?.message, appL10n.remoteDirectTokenRequired);
      expect(opener.calls, isEmpty);
    });

    test('a transport failure is retried with backoff, then reported as unreachable', () async {
      final phases = <HostLinkPhase>[];
      final opener = _Opener([
        const DshTransportException('connection refused'),
        const DshTransportException('connection refused'),
        const DshTransportException('connection refused'),
      ]);
      final link = DirectHostLink(
        baseUri: _baseUri,
        loadSecrets: () async => const DirectSecrets(token: 'tok-3'),
        saveCookie: (_) async {},
        open: opener.call,
        backoff: Backoff(initial: const Duration(milliseconds: 1), max: const Duration(milliseconds: 1), maxAttempts: 2),
      );
      addTearDown(link.close);
      link.statuses.listen((status) => phases.add(status.phase));

      await expectLater(link.open(), throwsA(_hostLinkError(HostLinkErrorKind.unreachable)));

      expect(opener.calls, hasLength(3), reason: 'initial attempt plus maxAttempts retries');
      expect(phases.where((phase) => phase == HostLinkPhase.reconnecting), hasLength(2));
      expect(phases.last, HostLinkPhase.failed, reason: 'the link stops retrying once the backoff is exhausted');
      expect(link.status.error?.retryable, isTrue);
    });

    test('retry after giving up opens again and connects', () async {
      final opener = _Opener([
        const DshTransportException('connection refused'),
        const DshTransportException('connection refused'),
        const DshTransportException('connection refused'),
        _FakeClient(cookie: _mintedCookie),
      ]);
      final link = DirectHostLink(
        baseUri: _baseUri,
        loadSecrets: () async => const DirectSecrets(token: 'tok-4'),
        saveCookie: (_) async {},
        open: opener.call,
        backoff: Backoff(initial: const Duration(milliseconds: 1), max: const Duration(milliseconds: 1), maxAttempts: 2),
      );
      addTearDown(link.close);

      await expectLater(link.open(), throwsA(_hostLinkError(HostLinkErrorKind.unreachable)));
      expect(link.status.phase, HostLinkPhase.failed);

      final connected = link.statuses.firstWhere((status) => status.phase == HostLinkPhase.connected);
      link.retry();
      await connected.timeout(const Duration(seconds: 2));

      expect(opener.calls, hasLength(4), reason: 'the retry button starts a fresh attempt');
      expect(link.status.phase, HostLinkPhase.connected);
    });
  });

  group('probeDirectHost', () {
    test('trims the token, forwards the cookie and closes the client it opened', () async {
      final client = _FakeClient(cookie: _storedCookie);
      final opener = _Opener([client]);

      final elapsed = await probeDirectHost(
        baseUri: _baseUri,
        token: '  tok-probe  ',
        cookie: _storedCookie,
        open: opener.call,
      );

      expect(elapsed, isA<Duration>());
      expect(opener.calls.single.baseUri, _baseUri);
      expect(opener.calls.single.token, 'tok-probe');
      expect(opener.calls.single.cookie, same(_storedCookie));
      expect(client.closed, isTrue, reason: '测试连接 must not leave a client behind');
    });

    test('a blank token is treated as no token', () async {
      final opener = _Opener([_FakeClient()]);

      await probeDirectHost(baseUri: _baseUri, token: '   ', open: opener.call);

      expect(opener.calls.single.token, isNull);
    });

    test('reports the failure instead of pretending the host is reachable', () async {
      final opener = _Opener([const DshHttpException(401, 'token rejected')]);

      await expectLater(
        probeDirectHost(baseUri: _baseUri, token: 'bad', open: opener.call),
        throwsA(isA<DshHttpException>()),
      );
      expect(opener.calls, hasLength(1));
    });
  });
}