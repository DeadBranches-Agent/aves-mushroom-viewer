import 'dart:async';
import 'dart:convert';

import 'package:aves/sftp/model/sftp_host.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

final SftpConnectionPool sftpConnectionPool = SftpConnectionPool._private();

// raised when the stored host key fingerprint does not match the server's
class SftpHostKeyMismatchException implements Exception {
  final String hostId, actualFingerprint;

  SftpHostKeyMismatchException(this.hostId, this.actualFingerprint);
}

// raised when connecting to a host with no pinned fingerprint and no `onUnknownHostKey` confirmation
class SftpHostKeyUnknownException implements Exception {
  final String hostId, actualFingerprint;

  SftpHostKeyUnknownException(this.hostId, this.actualFingerprint);
}

// one SSH connection per host, lazily established, reused across requests.
// - host key verification: computes the server key's SHA-256 fingerprint.
//   * a pinned fingerprint must match exactly, else `SftpHostKeyMismatchException` (connection refused).
//   * with no pinned fingerprint, `onUnknownHostKey` (set by the UI layer) is asked to confirm;
//     on confirmation the fingerprint is pinned via `sftpHosts.setFingerprint`.
//     without a handler, refuse with `SftpHostKeyUnknownException`.
// - auth: password or private key from `sftpHosts.getSecret`.
// - reconnects transparently when the connection dropped since last use.
// - closes all connections when the app is backgrounded (listens to `AvesApp.lifecycleStateNotifier`,
//   wired in `init`).
class SftpConnectionPool {
  final Map<String, Future<_SftpConnection>> _pool = {};

  // asks the user to trust a first-seen host key; returns true to trust and pin
  Future<bool> Function(SftpHost host, String fingerprint)? onUnknownHostKey;

  static const _connectTimeout = Duration(seconds: 15);
  static const _backgroundStates = {AppLifecycleState.paused, AppLifecycleState.detached};

  SftpConnectionPool._private();

  void init(ValueListenable<AppLifecycleState> lifecycleStateNotifier) {
    lifecycleStateNotifier.addListener(() {
      if (_backgroundStates.contains(lifecycleStateNotifier.value)) {
        unawaited(closeAll());
      }
    });
  }

  // connected, authenticated SFTP client for this host.
  // concurrent callers while connecting share the same pending connection attempt.
  Future<SftpClient> clientFor(SftpHost host) async {
    final pending = _pool[host.id];
    if (pending != null) {
      final connection = await pending;
      if (!connection.sshClient.isClosed) return connection.sftpClient;

      _dropIfCurrent(host.id, pending);
    }

    final connecting = _connect(host);
    _pool[host.id] = connecting;
    try {
      final connection = await connecting;
      return connection.sftpClient;
    } catch (error) {
      _dropIfCurrent(host.id, connecting);
      rethrow;
    }
  }

  // drops the cached connection so the next `clientFor` reconnects.
  // call after any request-level transport error.
  void invalidate(String hostId) => _pool.remove(hostId)?.then((v) => v.sshClient.close()).ignore();

  Future<void> closeAll() async {
    final connections = _pool.values.toList();
    _pool.clear();
    await Future.wait(connections.map((v) => v.then((connection) => connection.sshClient.close()).catchError((_) {})));
  }

  void _dropIfCurrent(String hostId, Future<_SftpConnection> connecting) {
    if (identical(_pool[hostId], connecting)) {
      _pool.remove(hostId)?.ignore();
    }
  }

  Future<_SftpConnection> _connect(SftpHost host) async {
    final secret = await sftpHosts.getSecret(host.id);
    final socket = await SSHSocket.connect(host.host, host.port, timeout: _connectTimeout);

    // dartssh2 awaits the verify handler, so the unknown key prompt can run inline during key exchange.
    // the handler cannot throw (its error would escape the transport), so the refusal reason
    // is captured here and thrown when the failed handshake surfaces.
    Exception? refusal;
    final sshClient = SSHClient(
      socket,
      username: host.username,
      onVerifyHostKey: (type, fingerprintBytes) async {
        final fingerprint = utf8.decode(fingerprintBytes);
        final pinned = sftpHosts.byId(host.id)?.hostKeyFingerprint;
        if (pinned != null) {
          if (pinned == fingerprint) return true;
          refusal = SftpHostKeyMismatchException(host.id, fingerprint);
          return false;
        }

        final confirm = onUnknownHostKey;
        if (confirm != null && await confirm(host, fingerprint)) {
          await sftpHosts.setFingerprint(host.id, fingerprint);
          return true;
        }

        refusal = SftpHostKeyUnknownException(host.id, fingerprint);
        return false;
      },
      identities: host.authType == SftpAuthType.privateKey && secret != null ? SSHKeyPair.fromPem(secret) : null,
      onPasswordRequest: host.authType == SftpAuthType.password ? () => secret : null,
    );

    try {
      final sftpClient = await sshClient.sftp();
      return _SftpConnection(sshClient, sftpClient);
    } catch (error) {
      unawaited(sshClient.close());
      final hostKeyRefusal = refusal;
      if (hostKeyRefusal != null) throw hostKeyRefusal;
      rethrow;
    }
  }
}

class _SftpConnection {
  final SSHClient sshClient;
  final SftpClient sftpClient;

  const _SftpConnection(this.sshClient, this.sftpClient);
}
