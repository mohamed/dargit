import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../backend.dart' show AuthMethod;
import '../util.dart';
import 'pktline.dart';
import 'transport.dart';

/// Smart HTTP(S) transport (protocol v0, stateless RPC).
class HttpTransport implements Transport {
  HttpTransport(this.url, this.options);
  final String url;
  final TransportOptions options;

  @override
  Future<UploadSession> openUpload() =>
      SmartUploadSession.open(_HttpChannel(url, options));

  @override
  Future<ReceiveSession> openReceive() =>
      SmartReceiveSession.open(_HttpChannel(url, options));
}

class _HttpChannel implements SmartChannel {
  _HttpChannel(String url, this.options) {
    var u = Uri.parse(url);
    final auth = options.auth;
    if (auth.method == AuthMethod.httpsToken) {
      final user = (auth.username ?? '').isEmpty ? 'git' : auth.username!;
      _authHeader = _basic(user, auth.password ?? '');
    } else if (u.userInfo.isNotEmpty) {
      final parts = u.userInfo.split(':');
      _authHeader = _basic(
          Uri.decodeComponent(parts[0]),
          parts.length > 1
              ? Uri.decodeComponent(parts.sublist(1).join(':'))
              : '');
    }
    u = u.replace(userInfo: '');
    var s = u.toString();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    _base = s;
    _client = HttpClient()
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..connectionTimeout = options.timeout
      ..idleTimeout = const Duration(seconds: 15)
      ..userAgent = 'git/2.0 (dartgit/0.1)';
  }

  final TransportOptions options;
  late final String _base;
  late final HttpClient _client;
  String? _authHeader;

  static String _basic(String user, String pass) =>
      'Basic ${base64.encode(utf8.encode('$user:$pass'))}';

  Future<HttpClientResponse> _send(HttpClientRequest req) async {
    if (_authHeader != null)
      req.headers.set(HttpHeaders.authorizationHeader, _authHeader!);
    final resp = await req.close().timeout(options.timeout);
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      await resp.drain<void>().catchError((_) {});
      throw GitError(_authHeader == null
          ? 'authentication required (HTTP ${resp.statusCode})'
          : 'authentication failed (HTTP ${resp.statusCode})');
    }
    if (resp.statusCode == 404) {
      await resp.drain<void>().catchError((_) {});
      throw GitError('repository not found (HTTP 404)');
    }
    if (resp.statusCode != 200) {
      final body = await resp.timeout(options.timeout).fold<List<int>>(
          [], (a, b) => a..addAll(b)).catchError((_) => <int>[]);
      final text = lenient(body).trim();
      throw GitError(
          'HTTP ${resp.statusCode}${text.isEmpty ? '' : ': ${text.split('\n').first}'}');
    }
    return resp;
  }

  @override
  Future<PktReader> advertise(String service) async {
    final Uri uri = Uri.parse('$_base/info/refs?service=$service');
    final req = await _client.getUrl(uri).timeout(options.timeout);
    final resp = await _send(req);
    if (resp.redirects.isNotEmpty) {
      final loc = resp.redirects.last.location;
      final abs = uri.resolveUri(loc).toString();
      final i = abs.indexOf('/info/refs');
      if (i > 0) _base = abs.substring(0, i);
    }
    final type = resp.headers.contentType?.mimeType ?? '';
    if (type != 'application/x-$service-advertisement') {
      await resp.drain<void>().catchError((_) {});
      throw GitError(
          'server does not speak the smart HTTP protocol (content type "$type")');
    }
    final r = PktReader(resp.timeout(options.timeout));
    final first = await r.readLine();
    if (first != '# service=$service')
      throw GitError('protocol error: bad service header');
    while (await r.read() != null) {}
    return r;
  }

  @override
  Future<PktReader> request(String service, Uint8List body) async {
    final req = await _client
        .postUrl(Uri.parse('$_base/$service'))
        .timeout(options.timeout);
    req.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/x-$service-request')
      ..set(HttpHeaders.acceptHeader, 'application/x-$service-result');
    req.contentLength = body.length;
    req.add(body);
    final resp = await _send(req);
    return PktReader(resp.timeout(options.timeout));
  }

  @override
  Future<void> close() async => _client.close(force: true);
}
