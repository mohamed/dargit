import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// A minimal ssh-agent on a Unix socket backed by in-memory keys.
class TestAgent {
  TestAgent._(this._server, this.path, this._clients);

  static Future<TestAgent> start(String path, List<SSHKeyPair> keys) async {
    final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix), 0);
    final agent = SSHKeyPairAgent(keys);
    final clients = <Socket>[];
    server.listen((sock) {
      clients.add(sock);
      var buf = <int>[];
      sock.listen((data) async {
        buf = [...buf, ...data];
        while (buf.length >= 4) {
          final len = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
          if (buf.length < 4 + len) break;
          final req = Uint8List.fromList(buf.sublist(4, 4 + len));
          buf = buf.sublist(4 + len);
          final resp = await agent.handleRequest(req);
          final n = resp.length;
          sock.add([
            (n >> 24) & 255,
            (n >> 16) & 255,
            (n >> 8) & 255,
            n & 255,
            ...resp
          ]);
        }
      }, onError: (_) {});
    });
    return TestAgent._(server, path, clients);
  }

  final ServerSocket _server;
  final String path;
  final List<Socket> _clients;

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _server.close();
  }
}
