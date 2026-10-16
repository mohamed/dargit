import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../credentials.dart';
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
    final creds = options.credentials;
    if (creds is UserPassword) {
      _authHeader = _basic(creds.username, creds.password);
    } else if (u.userInfo.isNotEmpty) {
      final parts = u.userInfo.split(':');
      _authHeader = _basic(
          Uri.decodeComponent(parts[0]),
          parts.length > 1
              ? Uri.decodeComponent(parts.sublist(1).join(':'))
              : '');
    }
    u = u.replace(userInfo: '');
    _origin = u;
    var s = u.toString();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    _base = s;
    _client = HttpClient()
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..connectionTimeout = options.timeout
      ..idleTimeout = const Duration(seconds: 15)
      ..userAgent = 'git/2.0 (dargit/$dargitVersion)';
  }

  final TransportOptions options;
  late String _base;
  late final Uri _origin;
  late final HttpClient _client;
  String? _authHeader;

  static String _basic(String user, String pass) =>
      'Basic ${base64.encode(utf8.encode('$user:$pass'))}';

  /// Credentials go only to the scheme, host and port they were given for,
  /// as curl sends them for git (no `CURLOPT_UNRESTRICTED_AUTH`).
  bool _mayAuthenticate(Uri u) =>
      u.scheme == _origin.scheme &&
      u.host.toLowerCase() == _origin.host.toLowerCase() &&
      u.port == _origin.port;

  void _authorize(HttpClientRequest req, Uri uri) {
    if (_authHeader != null && _mayAuthenticate(uri)) {
      req.headers.set(HttpHeaders.authorizationHeader, _authHeader!);
    }
  }

  Future<HttpClientResponse> _send(HttpClientRequest req) async =>
      _check(await req.close().timeout(options.timeout));

  /// Turns error statuses into [GitError]s.
  Future<HttpClientResponse> _check(HttpClientResponse resp) async {
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
    var uri = Uri.parse('$_base/info/refs?service=$service');
    // Redirects are followed here, not by HttpClient (which would send the
    // credentials to any host), and only for this first request, like
    // git's http.followRedirects=initial; later requests use the new base.
    HttpClientResponse resp;
    for (var hops = 0;; hops++) {
      final req = await _client.getUrl(uri).timeout(options.timeout);
      req.followRedirects = false;
      _authorize(req, uri);
      resp = await req.close().timeout(options.timeout);
      final location = resp.headers.value(HttpHeaders.locationHeader);
      if (!resp.isRedirect || location == null) break;
      await resp.drain<void>().catchError((_) {});
      if (hops == 5) throw GitError('too many HTTP redirects');
      uri = uri.resolve(location);
    }
    await _check(resp);
    final abs = uri.toString();
    final i = abs.indexOf('/info/refs');
    if (i > 0) _base = abs.substring(0, i);
    final type = resp.headers.contentType?.mimeType ?? '';
    if (type != 'application/x-$service-advertisement') {
      await resp.drain<void>().catchError((_) {});
      throw GitError(
          'server does not speak the smart HTTP protocol (content type "$type")');
    }
    final r = PktReader(resp.timeout(options.timeout));
    final first = await r.readLine();
    if (first != '# service=$service') {
      throw GitError('protocol error: bad service header');
    }
    while (await r.read() != null) {}
    return r;
  }

  @override
  Future<PktReader> request(String service, Uint8List body) async {
    final req = await _client
        .postUrl(Uri.parse('$_base/$service'))
        .timeout(options.timeout);
    req.followRedirects = false;
    req.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/x-$service-request')
      ..set(HttpHeaders.acceptHeader, 'application/x-$service-result');
    _authorize(req, Uri.parse('$_base/$service'));
    req.contentLength = body.length;
    req.add(body);
    final resp = await _send(req);
    return PktReader(resp.timeout(options.timeout));
  }

  @override
  Future<void> close() async => _client.close(force: true);
}
