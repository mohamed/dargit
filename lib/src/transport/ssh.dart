import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart'
    show
        SSHAuthError,
        SSHClient,
        SSHError,
        SSHHostKey,
        SSHIdentity,
        SSHKeyPair,
        SSHRawHostKey,
        SSHRawSignature,
        SSHSignature,
        SSHSocket;

import '../backend.dart' show AuthMethod;
import '../util.dart';
import 'transport.dart';

/// Smart protocol over SSH (`git-upload-pack '<path>'` exec channel).
class SshTransport implements Transport {
  SshTransport({
    required this.host,
    required this.port,
    required this.user,
    required this.path,
    required this.options,
  });

  final String host;
  final int port;
  final String? user;
  final String path;
  final TransportOptions options;

  String get hostKeyName => port == 22 ? host : '[$host]:$port';

  @override
  Future<UploadSession> openUpload() => SmartUploadSession.open(_channel());

  @override
  Future<ReceiveSession> openReceive() => SmartReceiveSession.open(_channel());

  StreamChannel _channel() => StreamChannel((service) async {
        final identities = await _identities();
        final SSHSocket socket;
        try {
          socket =
              await SSHSocket.connect(host, port, timeout: options.timeout);
        } on SocketException catch (e) {
          throw GitError('cannot connect to $host:$port: ${e.message}');
        }
        final auth = options.auth;
        final username =
            user ?? ((auth.username ?? '').isEmpty ? 'git' : auth.username!);
        String? hostKeyError;
        final client = SSHClient(
          socket,
          username: username,
          identities: identities.keys,
          onVerifyHostKey: (type, fp) {
            hostKeyError = _verifyHostKey(utf8.decode(fp));
            return hostKeyError == null;
          },
          handshakeTimeout: options.timeout,
          authTimeout: options.timeout,
        );
        try {
          await client.authenticated.timeout(options.timeout);
          final session = await client
              .execute('$service ${shellQuote(path)}')
              .timeout(options.timeout);
          return StreamEndpoint(
            output: session.stdout,
            write: (data) => session.stdin.add(data),
            dispose: () async {
              session.close();
              unawaited(client.close());
              await identities.dispose();
            },
          );
        } catch (e) {
          unawaited(client.close());
          await identities.dispose();
          if (hostKeyError != null) throw GitError(hostKeyError!);
          if (e is SSHAuthError) {
            throw GitError('SSH authentication failed for $username@$host');
          }
          if (e is SSHError) throw GitError('SSH error: $e');
          rethrow;
        }
      }, options.timeout);

  /// Returns null when the key is accepted, else an error message.
  String? _verifyHostKey(String fingerprint) {
    final path = options.knownHostsPath;
    if (path == null) return null;
    final f = File(path);
    Map<String, dynamic> known = {};
    if (f.existsSync()) {
      try {
        final decoded = jsonDecode(f.readAsStringSync());
        if (decoded is Map<String, dynamic>) known = decoded;
      } on FormatException {
        return 'known hosts file $path is corrupt';
      }
    }
    final pinned = known[hostKeyName];
    if (pinned == null) {
      known[hostKeyName] = fingerprint;
      f.parent.createSync(recursive: true);
      writeFileAtomic(
          path, utf8Bytes(const JsonEncoder.withIndent('  ').convert(known)));
      return null;
    }
    if (pinned == fingerprint) return null;
    return 'host key for $hostKeyName changed (expected $pinned, got $fingerprint); '
        'refusing to connect';
  }

  Future<_Identities> _identities() async {
    final auth = options.auth;
    switch (auth.method) {
      case AuthMethod.sshKey:
        final path = auth.sshKeyPath;
        if (path == null || path.isEmpty) {
          throw GitError('no SSH key configured');
        }
        final f = File(path);
        if (!f.existsSync()) throw GitError('SSH key $path not found');
        final pem = f.readAsStringSync();
        final passphrase =
            (auth.sshPassphrase ?? '').isEmpty ? null : auth.sshPassphrase;
        try {
          if (passphrase == null && SSHKeyPair.isEncryptedPem(pem)) {
            throw GitError(
                'SSH key $path is encrypted; a passphrase is required');
          }
          // The public key is derived from the private key; no .pub needed.
          return _Identities(SSHKeyPair.fromPem(pem, passphrase), null);
        } on GitError {
          rethrow;
        } on Object catch (e) {
          throw GitError('cannot load SSH key $path: $e');
        }
      case AuthMethod.sshAgent:
        final sock = (auth.sshKeyPath ?? '').isNotEmpty
            ? auth.sshKeyPath
            : Platform.environment['SSH_AUTH_SOCK'];
        return _Identities.fromAgent(sock);
      case AuthMethod.none:
      case AuthMethod.httpsToken:
        return _Identities(const [], null);
    }
  }
}

class _Identities {
  _Identities(this.keys, this._agent);
  final List<SSHIdentity> keys;
  final _AgentClient? _agent;

  static Future<_Identities> fromAgent(String? sock) async {
    if (Platform.isWindows || sock == null || sock.isEmpty) {
      throw GitError('no SSH agent available (SSH_AUTH_SOCK not set)');
    }
    final agent = await _AgentClient.connect(sock);
    try {
      final ids = await agent.identities();
      if (ids.isEmpty) throw GitError('the SSH agent has no keys');
      return _Identities(ids, agent);
    } catch (_) {
      await agent.close();
      rethrow;
    }
  }

  Future<void> dispose() async => _agent?.close();
}

/// Minimal ssh-agent protocol client (identities + sign) over a Unix socket.
class _AgentClient {
  _AgentClient(this._socket) {
    _sub = _socket.listen((d) {
      _buf.add(d);
      _pump();
    },
        onError: (Object e) => _fail(e),
        onDone: () => _fail(GitError('SSH agent closed')));
  }

  static Future<_AgentClient> connect(String path) async {
    try {
      // The socket is owned (and destroyed) by the returned client.
      // ignore: close_sinks
      final s = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix), 0);
      return _AgentClient(s);
    } on SocketException catch (e) {
      throw GitError('cannot connect to SSH agent: ${e.message}');
    }
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder();
  final _waiting = <Completer<Uint8List>>[];

  void _pump() {
    while (_waiting.isNotEmpty) {
      final b = _buf.toBytes();
      if (b.length < 4) return;
      final len = readUint32(b, 0);
      if (b.length < 4 + len) return;
      final msg = Uint8List.fromList(b.sublist(4, 4 + len));
      _buf.clear();
      _buf.add(b.sublist(4 + len));
      _waiting.removeAt(0).complete(msg);
    }
  }

  void _fail(Object e) {
    for (final c in _waiting) {
      if (!c.isCompleted) c.completeError(e);
    }
    _waiting.clear();
  }

  Future<Uint8List> _request(List<int> body) {
    final c = Completer<Uint8List>();
    _waiting.add(c);
    final b = BytesBuilder();
    writeUint32(b, body.length);
    b.add(body);
    _socket.add(b.takeBytes());
    return c.future;
  }

  static void _str(BytesBuilder b, List<int> s) {
    writeUint32(b, s.length);
    b.add(s);
  }

  Future<List<SSHIdentity>> identities() async {
    final resp = await _request([11]);
    if (resp.isEmpty || resp[0] != 12) {
      throw GitError('SSH agent refused to list keys');
    }
    final n = readUint32(resp, 1);
    var p = 5;
    final out = <SSHIdentity>[];
    for (var i = 0; i < n; i++) {
      final blobLen = readUint32(resp, p);
      final blob = Uint8List.fromList(resp.sublist(p + 4, p + 4 + blobLen));
      p += 4 + blobLen;
      final cLen = readUint32(resp, p);
      final comment =
          utf8.decode(resp.sublist(p + 4, p + 4 + cLen), allowMalformed: true);
      p += 4 + cLen;
      final keyType = SSHHostKey.getType(blob);
      final isRsa = keyType == 'ssh-rsa';
      out.add(SSHIdentity.custom(
        type: isRsa ? 'rsa-sha2-256' : keyType,
        publicKey: SSHRawHostKey(blob),
        comment: comment,
        shouldProbe: true,
        signer: (data) => _sign(blob, data, isRsa ? 2 : 0),
      ));
    }
    return out;
  }

  Future<SSHSignature> _sign(Uint8List blob, Uint8List data, int flags) async {
    final b = BytesBuilder()..addByte(13);
    _str(b, blob);
    _str(b, data);
    writeUint32(b, flags);
    final resp = await _request(b.takeBytes());
    if (resp.isEmpty || resp[0] != 14) {
      throw GitError('SSH agent refused to sign');
    }
    final len = readUint32(resp, 1);
    return SSHRawSignature(Uint8List.fromList(resp.sublist(5, 5 + len)));
  }

  Future<void> close() async {
    await _sub.cancel();
    _socket.destroy();
  }
}
