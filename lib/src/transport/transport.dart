import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../credentials.dart';
import '../hash.dart';
import '../util.dart';
import 'http.dart';
import 'local.dart';
import 'pktline.dart';
import 'ssh.dart';

/// A ref update sent to the remote.
class RefUpdate {
  RefUpdate(this.name, this.oldId, this.newId);
  final String name;
  final String oldId; // all zeros when creating
  final String newId; // all zeros when deleting
}

/// Connection to `git-upload-pack` (fetch side).
abstract class UploadSession {
  /// Advertised refs (`refs/heads/*`, `refs/tags/*`, ...) -> id.
  Map<String, String> get refs;

  /// Target of the remote HEAD if advertised (e.g. `refs/heads/main`).
  String? get head;

  /// The commit the remote HEAD points at, also when it is detached.
  String? get headId;

  /// The remote repository's object format.
  ObjectFormat get format;

  /// Requests a pack with [wants], telling the server we have [haves].
  Future<Uint8List> fetchPack(List<String> wants, List<String> haves);

  Future<void> close();
}

/// Connection to `git-receive-pack` (push side).
abstract class ReceiveSession {
  Map<String, String> get refs;

  /// The remote repository's object format.
  ObjectFormat get format;

  /// Sends [updates] and [pack]; throws [GitError] when a ref is rejected.
  Future<void> push(List<RefUpdate> updates, Uint8List? pack);

  Future<void> close();
}

abstract class Transport {
  Future<UploadSession> openUpload();
  Future<ReceiveSession> openReceive();
}

class TransportOptions {
  TransportOptions(
      {this.credentials = const NoCredentials(),
      this.verifyHostKey,
      required this.timeout});
  final Credentials credentials;
  final HostKeyVerifier? verifyHostKey;
  final Duration timeout;
}

final _scpLike = RegExp(r'^(?:([^@/]+)@)?([^:/]+):(.*)$');

/// Test hook: when set, used instead of the URL-based choice below (only
/// effective in the isolate that sets it, so use `useIsolates: false`).
Transport? Function(String url, TransportOptions options)?
    debugTransportFactory;

/// Chooses a transport for [url].
Transport openTransport(String url, TransportOptions options) {
  final override = debugTransportFactory?.call(url, options);
  if (override != null) return override;
  final lower = url.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return HttpTransport(url, options);
  }
  if (lower.startsWith('ssh://') || lower.startsWith('git+ssh://')) {
    final u = Uri.parse(
        url.replaceFirst(RegExp('^git\\+', caseSensitive: false), ''));
    var path = Uri.decodeComponent(u.path);
    if (path.startsWith('/~')) path = path.substring(1);
    return SshTransport(
      host: u.host,
      port: u.hasPort ? u.port : 22,
      user: u.userInfo.isEmpty
          ? null
          : Uri.decodeComponent(u.userInfo.split(':').first),
      path: path,
      options: options,
    );
  }
  if (lower.startsWith('file://')) {
    return LocalTransport(Uri.parse(url).toFilePath());
  }
  final isWindowsDrive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url);
  final m = _scpLike.firstMatch(url);
  if (!isWindowsDrive &&
      m != null &&
      !url.contains('://') &&
      !Directory(url).existsSync()) {
    return SshTransport(
      host: m.group(2)!,
      port: 22,
      user: m.group(1),
      path: m.group(3)!,
      options: options,
    );
  }
  if (url.contains('://')) throw GitError('unsupported URL scheme: $url');
  return LocalTransport(url);
}

// ---------------------------------------------------------------------------
// Smart protocol (v0) on top of a byte channel

/// A channel speaking the smart protocol: either stateful (SSH, process) or
/// stateless (HTTP: one advertisement GET and one POST).
abstract class SmartChannel {
  /// Starts [service] and returns a reader positioned at the ref
  /// advertisement.
  Future<PktReader> advertise(String service);

  /// Sends [body] and returns a reader for the response.
  Future<PktReader> request(String service, Uint8List body);

  Future<void> close();
}

class Advertisement {
  final refs = <String, String>{};
  final caps = <String>{};
  String? head;
  String? headId;

  /// From the `object-format` capability; servers that do not send it
  /// only speak SHA-1.
  ObjectFormat get format {
    for (final c in caps) {
      if (c.startsWith('object-format=')) {
        return ObjectFormat.parse(c.substring('object-format='.length));
      }
    }
    return ObjectFormat.sha1;
  }

  /// The capability a client echoes to confirm the object format.
  List<String> get formatCap => [
        if (caps.any((c) => c.startsWith('object-format=')))
          'object-format=${format.name}',
      ];
}

Future<Advertisement> readAdvertisement(PktReader r) async {
  final ad = Advertisement();
  var first = true;
  while (true) {
    final line = await r.readLine();
    if (line == null) break;
    if (first && line.startsWith('version ')) continue;
    var l = line;
    if (first) {
      first = false;
      final nul = l.indexOf('\u0000');
      if (nul >= 0) {
        ad.caps
            .addAll(l.substring(nul + 1).split(' ').where((c) => c.isNotEmpty));
        l = l.substring(0, nul);
      }
    }
    if (l.length < 42) continue;
    final sp = l.indexOf(' ');
    if (sp < 0) continue;
    final id = l.substring(0, sp), name = l.substring(sp + 1);
    if (name == 'capabilities^{}' || name.endsWith('^{}')) continue;
    ad.refs[name] = id;
  }
  for (final c in ad.caps) {
    if (c.startsWith('symref=HEAD:')) {
      ad.head = c.substring('symref=HEAD:'.length);
    }
  }
  if (ad.head == null && ad.refs.containsKey('HEAD')) {
    // Older servers: guess from the id.
    for (final e in ad.refs.entries) {
      if (e.key.startsWith('refs/heads/') && e.value == ad.refs['HEAD']) {
        ad.head = e.key;
        break;
      }
    }
  }
  ad.headId = ad.refs.remove('HEAD');
  return ad;
}

const agent = 'agent=dartgit/0.1';

class SmartUploadSession implements UploadSession {
  SmartUploadSession._(this._ch, this._ad);

  static Future<SmartUploadSession> open(SmartChannel ch) async {
    try {
      final r = await ch.advertise('git-upload-pack');
      return SmartUploadSession._(ch, await readAdvertisement(r));
    } catch (_) {
      await ch.close();
      rethrow;
    }
  }

  final SmartChannel _ch;
  final Advertisement _ad;

  @override
  Map<String, String> get refs => _ad.refs;
  @override
  ObjectFormat get format => _ad.format;
  @override
  String? get head => _ad.head;
  @override
  String? get headId => _ad.headId;

  @override
  Future<Uint8List> fetchPack(List<String> wants, List<String> haves) async {
    if (wants.isEmpty) throw GitError('nothing to fetch');
    final caps = <String>[
      if (_ad.caps.contains('side-band-64k'))
        'side-band-64k'
      else if (_ad.caps.contains('side-band'))
        'side-band',
      if (_ad.caps.contains('ofs-delta')) 'ofs-delta',
      if (_ad.caps.contains('no-progress')) 'no-progress',
      ..._ad.formatCap,
      agent,
    ];
    final body = BytesBuilder(copy: false);
    for (var i = 0; i < wants.length; i++) {
      body.add(pkt(i == 0
          ? 'want ${wants[i]} ${caps.join(' ')}\n'
          : 'want ${wants[i]}\n'));
    }
    body.add(flushPkt);
    for (final h in haves) {
      body.add(pkt('have $h\n'));
    }
    body.add(pkt('done\n'));
    final r = await _ch.request('git-upload-pack', body.takeBytes());
    // ACK/NAK lines (one or two) precede the pack.
    final sideband =
        caps.contains('side-band-64k') || caps.contains('side-band');
    while (true) {
      if (!sideband && await r.peek4() == 'PACK') return r.readToEnd();
      final d = await r.read();
      if (d == null) continue;
      final text = lenient(d.length > 12 ? d.sublist(0, 12) : d);
      if (text.startsWith('NAK') ||
          text.startsWith('ACK ') ||
          text.startsWith('shallow ') ||
          text.startsWith('unshallow ')) {
        continue;
      }
      if (sideband && d.isNotEmpty && d[0] >= 1 && d[0] <= 3) {
        return r.readSideband(d);
      }
      throw GitError('protocol error: unexpected "${text.trim()}"');
    }
  }

  @override
  Future<void> close() => _ch.close();
}

class SmartReceiveSession implements ReceiveSession {
  SmartReceiveSession._(this._ch, this._ad);

  static Future<SmartReceiveSession> open(SmartChannel ch) async {
    try {
      final r = await ch.advertise('git-receive-pack');
      return SmartReceiveSession._(ch, await readAdvertisement(r));
    } catch (_) {
      await ch.close();
      rethrow;
    }
  }

  final SmartChannel _ch;
  final Advertisement _ad;

  @override
  Map<String, String> get refs => _ad.refs;
  @override
  ObjectFormat get format => _ad.format;

  @override
  Future<void> push(List<RefUpdate> updates, Uint8List? pack) async {
    if (updates.isEmpty) return;
    final caps = <String>[
      'report-status',
      if (_ad.caps.contains('ofs-delta')) 'ofs-delta',
      if (_ad.caps.contains('atomic') && updates.length > 1) 'atomic',
      ..._ad.formatCap,
      agent,
    ];
    if (updates.any((u) => isZeroId(u.newId)) &&
        !_ad.caps.contains('delete-refs')) {
      throw GitError('remote does not support deleting refs');
    }
    final body = BytesBuilder(copy: false);
    for (var i = 0; i < updates.length; i++) {
      final u = updates[i];
      final line = '${u.oldId} ${u.newId} ${u.name}';
      body.add(pkt(i == 0 ? '$line\u0000${caps.join(' ')}\n' : '$line\n'));
    }
    body.add(flushPkt);
    if (updates.any((u) => !isZeroId(u.newId))) {
      body.add(pack ?? Uint8List(0));
    }
    final r = await _ch.request('git-receive-pack', body.takeBytes());
    final unpack = await r.readLine();
    if (unpack == null || !unpack.startsWith('unpack ')) {
      throw GitError('protocol error: bad push status "$unpack"');
    }
    if (unpack != 'unpack ok') {
      throw GitError('remote failed to unpack: ${unpack.substring(7)}');
    }
    final errors = <String>[];
    while (true) {
      final line = await r.readLine();
      if (line == null) break;
      if (line.startsWith('ng ')) errors.add(line.substring(3));
    }
    if (errors.isNotEmpty) {
      throw GitError('push rejected: ${errors.join('; ')}');
    }
  }

  @override
  Future<void> close() => _ch.close();
}

/// The two ends of a running service (SSH exec channel or process).
class StreamEndpoint {
  StreamEndpoint(
      {required this.output, required this.write, required this.dispose});
  final Stream<List<int>> output;
  final void Function(Uint8List data) write;
  final Future<void> Function() dispose;
}

/// Smart protocol over a bidirectional stream (SSH exec channel, process).
class StreamChannel implements SmartChannel {
  StreamChannel(this._start, this.timeout);

  final Future<StreamEndpoint> Function(String service) _start;
  final Duration timeout;
  StreamEndpoint? _ep;
  PktReader? _reader;
  bool _requested = false;

  @override
  Future<PktReader> advertise(String service) async {
    final ep = _ep = await _start(service);
    return _reader = PktReader(ep.output.timeout(timeout));
  }

  @override
  Future<PktReader> request(String service, Uint8List body) async {
    _requested = true;
    _ep!.write(body);
    return _reader!;
  }

  @override
  Future<void> close() async {
    final ep = _ep;
    if (ep == null) return;
    _ep = null;
    try {
      // Tell the server we are done when no request was made.
      if (!_requested) ep.write(flushPkt);
    } catch (_) {
      // Connection already gone.
    }
    try {
      await _reader?.cancel();
    } catch (_) {}
    await ep.dispose();
  }
}

String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
