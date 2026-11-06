import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';

import '../link_status.dart';
import 'direct_host_config.dart';

/// Opens the HTTP/WebSocket client for a direct host. Injectable so tests can
/// decide when a connect finishes and what it throws.
typedef DirectClientOpener = Future<DshClient> Function({
  required Uri baseUri,
  String? token,
  DshCookie? cookie,
});

Future<DshClient> _openDirect({required Uri baseUri, String? token, DshCookie? cookie}) =>
    DshClient.connect(baseUri: baseUri, token: token, cookie: cookie);

/// "测试连接": opens once, closes, and reports how long that took. Throws when
/// the host cannot be reached or the token is rejected.
Future<Duration> probeDirectHost({
  required Uri baseUri,
  required String token,
  DshCookie? cookie,
  DirectClientOpener? open,
}) async {
  final watch = Stopwatch()..start();
  final client = await (open ?? _openDirect)(
    baseUri: baseUri,
    token: token.trim().isEmpty ? null : token.trim(),
    cookie: cookie,
  );
  watch.stop();
  await client.close().catchError((_) {});
  return watch.elapsed;
}

/// A DSH server reached straight over its published HTTPS URL: `dsh web`
/// behind nginx, the person supplies the URL and an access token, and the phone
/// talks to the engine through the proxy.
///
/// The token is only needed to mint the 30-day session cookie; once that cookie
/// is stored the link resumes without it, and a 401 falls back to the token.
class DirectHostLink implements HostLink, NetworkInspectableHostLink {
  DirectHostLink({
    required this.baseUri,
    required this._loadSecrets,
    required this._saveCookie,
    DirectClientOpener? open,
    Stream<void>? kicks,
    Backoff? backoff,
    this.keepAliveInterval = const Duration(seconds: 20),
    this.retryFirstOpen = true,
  }) : _open = open ?? _openDirect,
       _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  final Uri baseUri;
  final Future<DirectSecrets> Function() _loadSecrets;
  final Future<void> Function(DshCookie cookie) _saveCookie;
  final DirectClientOpener _open;
  final Backoff _backoff;
  final Duration keepAliveInterval;

  /// False for "测试连接": report the first failure instead of retrying.
  final bool retryFirstOpen;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();

  StreamSubscription<void>? _kickSub;
  Timer? _keepAlive;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _client;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _lost = false;
  Duration? _lastConnect;

  @override
  HostLinkStatus get status => _status;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  @override
  Stream<DshClient> get clients => _clients.stream;

  @override
  Future<DshClient> open() {
    final existing = currentClient;
    if (existing != null) return Future.value(existing);
    return _opening ??= _openLoop().whenComplete(() => _opening = null);
  }

  @override
  void kick() {
    if (_closed || _status.isConnected) {
      if (_status.isConnected) unawaited(_check());
      return;
    }
    _delay.skip();
  }

  @override
  void retry() {
    if (_closed) return;
    _backoff.reset();
    _delay.skip();
    if (!_status.isBusy && !_status.isConnected) unawaited(open().then<void>((_) {}, onError: (Object _) {}));
  }

  Future<DshClient> _openLoop() async {
    var first = true;
    while (!_closed) {
      _emit(HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.login, attempt: _backoff.attempt));
      try {
        final client = await _attempt();
        return client;
      } on HostLinkError catch (error) {
        if (_closed) rethrow;
        final retryable = error.retryable && (retryFirstOpen || !first) && !_backoff.exhausted;
        first = false;
        if (!retryable) {
          _emit(HostLinkStatus(HostLinkPhase.failed, error: error, attempt: _backoff.attempt));
          rethrow;
        }
        final wait = _backoff.next();
        _emit(
          HostLinkStatus(
            HostLinkPhase.reconnecting,
            error: error,
            attempt: _backoff.attempt,
            nextRetryAt: DateTime.now().add(wait),
          ),
        );
        await _delay.wait(wait);
      } catch (error) {
        if (_closed) rethrow;
        final wrapped = HostLinkError(HostLinkErrorKind.other, appL10n.remoteErrHostUnreachable, detail: '$error');
        _emit(HostLinkStatus(HostLinkPhase.failed, error: wrapped, attempt: _backoff.attempt));
        throw wrapped;
      }
    }
    throw StateError('link closed');
  }

  Future<DshClient> _attempt() async {
    final watch = Stopwatch()..start();
    final secrets = await _loadSecrets();
    if (!secrets.canConnect) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteDirectTokenRequired);
    }

    // Prefer the stored cookie: it avoids spending the token, which `dsh web`
    // rotates on every restart. A 401 means it expired — log in again below.
    if (secrets.cookie != null) {
      try {
        return await _connected(await _open(baseUri: baseUri, cookie: secrets.cookie), watch.elapsed);
      } on DshHttpException catch (error) {
        if (!error.isUnauthorized && !error.isForbidden) rethrow;
        if (!secrets.hasToken) {
          throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteErrDshSignInExpired, detail: '$error');
        }
      } on DshProtocolException catch (error) {
        // A refused/fenced upgrade looks like a protocol error on some proxies.
        if (!secrets.hasToken) {
          throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteErrDshSignInExpired, detail: '$error');
        }
      }
    }

    if (!secrets.hasToken) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteDirectTokenRequired);
    }
    try {
      return await _connected(await _open(baseUri: baseUri, token: secrets.token), watch.elapsed);
    } on DshHttpException catch (error) {
      throw HostLinkError(
        HostLinkErrorKind.authFailed,
        error.isUnauthorized || error.isForbidden
            ? appL10n.remoteErrDshTokenRejected
            : appL10n.remoteErrDshSignIn,
        detail: '$error',
        // Only a network-shaped status is worth retrying; a rejected token is not.
        retryable: error.statusCode >= 500,
      );
    } on DshTransportException catch (error) {
      throw HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrHostUnreachable, detail: '$error', retryable: true);
    } on TimeoutException catch (error) {
      throw HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrSignInTimeout, detail: '$error', retryable: true);
    } on DshProtocolException catch (error) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteErrDshSignIn, detail: '$error');
    }
  }

  /// The HTTP connection behind [client]; null for a non-HTTP carrier.
  static DshConnection? _connectionOf(DshClient client) {
    final carrier = client.carrier;
    return carrier is DshHttpCarrier ? carrier.connection : null;
  }

  Future<DshClient> _connected(DshClient client, Duration connectDuration) async {
    if (_closed) {
      await client.close().catchError((_) {});
      throw StateError('link closed');
    }
    final previous = _client;
    _client = client;
    _lastConnect = connectDuration;
    _backoff.reset();
    _lost = false;
    // Persisting the cookie keeps the next start (and a reconnect) from
    // spending a token that may already have rotated.
    final cookie = _connectionOf(client)?.cookie;
    if (cookie != null) unawaited(_saveCookie(cookie).catchError((_) {}));
    _watchHealth(client);
    _emit(HostLinkStatus(HostLinkPhase.connected, completed: const {HostLinkStep.login}));
    if (previous != null && !identical(previous, client)) {
      _clients.add(client);
      unawaited(previous.close().catchError((_) {}));
    }
    return client;
  }

  /// Keeps the link honest: a periodic `GET /` over the same cookie notices a
  /// proxy or engine that went away, and a 401 expires us back through the token.
  void _watchHealth(DshClient client) {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(keepAliveInterval, (_) => unawaited(_check()));
  }

  Future<void> _check() async {
    final client = _client;
    if (client == null || !identical(_client, client) || _lost) return;
    final connection = _connectionOf(client);
    if (connection == null) return;
    final health = await connection.checkHealth().catchError((_) => DshHealth.unreachable);
    if (!identical(_client, client) || _closed) return;
    switch (health) {
      case DshHealth.ok:
        return;
      case DshHealth.unauthorized:
        _drop(client, HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteErrDshSignInExpired, retryable: true));
      case DshHealth.unreachable:
        _drop(client, HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrHostUnreachable, retryable: true));
    }
  }

  /// The host stopped answering: keep the link, start recovering.
  void _drop(DshClient client, HostLinkError error) {
    if (_closed || _lost || !identical(_client, client)) return;
    _lost = true;
    _keepAlive?.cancel();
    _client = null;
    unawaited(client.close().catchError((_) {}));
    if (!identical(_status.phase, HostLinkPhase.connecting) && !_status.isConnected) return;
    _emit(HostLinkStatus(HostLinkPhase.reconnecting, error: error, attempt: _backoff.attempt));
    unawaited(open().then<void>((_) {}, onError: (Object _) {}));
  }

  @override
  Future<RemoteNetworkStatus?> inspectNetwork() async {
    final client = _client;
    final connection = client == null ? null : _connectionOf(client);
    if (client == null || connection == null) return null;
    final watch = Stopwatch()..start();
    final health = await connection.checkHealth().catchError((_) => DshHealth.unreachable);
    watch.stop();
    if (health != DshHealth.ok) return null;
    return RemoteNetworkStatus(
      roundTripTime: watch.elapsed,
      connectDuration: _lastConnect,
      observedAt: DateTime.now(),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepAlive?.cancel();
    _delay.skip();
    await _kickSub?.cancel();
    _kickSub = null;
    final client = _client;
    _client = null;
    await client?.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }

  void _emit(HostLinkStatus next) {
    if (_closed) return;
    _status = next;
    if (!_statuses.isClosed) _statuses.add(next);
  }
}