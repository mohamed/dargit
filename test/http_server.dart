import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'helpers.dart';

/// Serves bare repositories under [root] with `git http-backend` (CGI),
/// requiring HTTP Basic credentials [user]:[password].
class GitHttpServer {
  GitHttpServer._(this._server, this.root);

  static Future<GitHttpServer> start(String root,
      {String user = 'git', String password = 'secret'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = GitHttpServer._(server, root);
    final expected = 'Basic ${base64.encode(utf8.encode('$user:$password'))}';
    server.listen((req) async {
      try {
        if (req.headers.value(HttpHeaders.authorizationHeader) != expected) {
          req.response
            ..statusCode = 401
            ..headers.set('WWW-Authenticate', 'Basic realm="git"');
          await req.response.close();
          return;
        }
        await s._cgi(req, user);
      } catch (e, st) {
        stderr.writeln('test http server: $e\n$st');
        try {
          req.response.statusCode = 500;
          await req.response.close();
        } catch (_) {}
      }
    });
    return s;
  }

  final HttpServer _server;
  final String root;
  int requests = 0;

  String url(String repo) => 'http://127.0.0.1:${_server.port}/$repo';

  Future<void> _cgi(HttpRequest req, String user) async {
    requests++;
    final body = BytesBuilder();
    await req.forEach(body.add);
    final input = body.takeBytes();
    final p = await Process.start('git', [
      'http-backend'
    ], environment: {
      ...gitEnv,
      'GIT_PROJECT_ROOT': root,
      'GIT_HTTP_EXPORT_ALL': '1',
      'PATH_INFO': req.uri.path,
      'QUERY_STRING': req.uri.query,
      'REQUEST_METHOD': req.method,
      'CONTENT_TYPE': req.headers.contentType?.toString() ?? '',
      'CONTENT_LENGTH': '${input.length}',
      'REMOTE_USER': user,
      'REMOTE_ADDR': '127.0.0.1',
    });
    p.stdin.add(input);
    await p.stdin.close();
    final out = BytesBuilder();
    final err = p.stderr.drain<void>();
    await p.stdout.forEach(out.add);
    await err;
    await p.exitCode;
    final bytes = out.takeBytes();
    var split = _indexOf(bytes, [13, 10, 13, 10]);
    var sepLen = 4;
    if (split < 0) {
      split = _indexOf(bytes, [10, 10]);
      sepLen = 2;
    }
    final head = latin1.decode(bytes.sublist(0, split));
    final res = req.response;
    for (final line in head.split(RegExp(r'\r?\n'))) {
      final c = line.indexOf(':');
      if (c < 0) continue;
      final k = line.substring(0, c).trim(), v = line.substring(c + 1).trim();
      if (k.toLowerCase() == 'status') {
        res.statusCode = int.parse(v.split(' ').first);
      } else {
        res.headers.set(k, v);
      }
    }
    res.add(Uint8List.sublistView(bytes, split + sepLen));
    await res.close();
  }

  Future<void> close() => _server.close(force: true);
}

int _indexOf(Uint8List b, List<int> pat) {
  outer:
  for (var i = 0; i + pat.length <= b.length; i++) {
    for (var j = 0; j < pat.length; j++) {
      if (b[i + j] != pat[j]) continue outer;
    }
    return i;
  }
  return -1;
}
