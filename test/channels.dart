// Smart-protocol channels backed by git's own upload-pack and
// receive-pack (`--stateless-rpc`, as git http-backend runs them).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dargit/src/transport/pktline.dart';
import 'package:dargit/src/transport/transport.dart';

import 'golden.dart';

/// Splits pkt-lines up to the first flush.
List<String> _pktLines(Uint8List b) {
  final out = <String>[];
  var p = 0;
  while (p + 4 <= b.length) {
    final len = int.parse(ascii.decode(b.sublist(p, p + 4)), radix: 16);
    if (len == 0) break;
    out.add(utf8.decode(b.sublist(p + 4, p + len)));
    p += len;
  }
  return out;
}

/// [bytes] as a stream of small chunks, as a network delivers them.
Stream<List<int>> chunked(List<int> bytes) => Stream.fromIterable([
      for (var i = 0; i < bytes.length; i += 64)
        bytes.sublist(i, i + 64 > bytes.length ? bytes.length : i + 64),
    ]);

/// A [SmartChannel] running git's service in [dir] for each request, with
/// the advertised capabilities filtered through [caps].
class GitChannel implements SmartChannel {
  GitChannel(this.dir, {this.caps = _all, this.extraRefs = const []});
  final String dir;
  final Iterable<String> Function(List<String>) caps;

  /// `<id> <name>` lines added to git's advertisement (refs git would never
  /// advertise, e.g. names it rejects).
  final List<String> extraRefs;
  var closed = false;

  static Iterable<String> _all(List<String> c) => c;

  @override
  Future<PktReader> advertise(String service) async {
    final raw = await cliBytes(
        [service.substring(4), '--stateless-rpc', '--advertise-refs', dir],
        dir);
    final lines = _pktLines(raw);
    final out = BytesBuilder();
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i];
      if (i == 0) {
        final nul = l.indexOf('\u0000');
        final c = l.substring(nul + 1).trim().split(' ');
        l = '${l.substring(0, nul)}\u0000${caps(c).join(' ')}\n';
      }
      out.add(pkt(l));
    }
    for (final r in extraRefs) {
      out.add(pkt('$r\n'));
    }
    out.add(flushPkt);
    return PktReader(chunked(out.takeBytes()));
  }

  @override
  Future<PktReader> request(String service, Uint8List body) async =>
      PktReader(chunked(await cliBytes(
          [service.substring(4), '--stateless-rpc', dir], dir,
          input: body)));

  @override
  Future<void> close() async => closed = true;
}

/// Git's advertisement, then a scripted [response].
class ScriptedChannel extends GitChannel {
  ScriptedChannel(super.dir, this.response, {super.caps});
  final List<int> response;

  @override
  Future<PktReader> request(String service, Uint8List body) async =>
      PktReader(chunked(response));
}

Iterable<String> Function(List<String>) without(List<String> drop) =>
    (c) => c.where((x) => !drop.any(x.startsWith));

/// A [Transport] over [channel], for `debugTransportFactory`.
class ChannelTransport implements Transport {
  ChannelTransport(this.channel);
  final GitChannel channel;

  @override
  Future<UploadSession> openUpload() => SmartUploadSession.open(channel);

  @override
  Future<ReceiveSession> openReceive() => SmartReceiveSession.open(channel);
}
