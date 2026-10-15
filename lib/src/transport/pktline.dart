import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../util.dart';

/// Encodes one pkt-line.
Uint8List pkt(String line) => pktBytes(utf8.encode(line));

Uint8List pktBytes(List<int> data) {
  final len = data.length + 4;
  if (len > 65520) throw GitError('pkt-line too long');
  return Uint8List.fromList(
      [...ascii.encode(len.toRadixString(16).padLeft(4, '0')), ...data]);
}

final Uint8List flushPkt = Uint8List.fromList(ascii.encode('0000'));

/// Reads pkt-lines (and raw data) from a byte stream.
class PktReader {
  PktReader(Stream<List<int>> stream) : _it = StreamIterator(stream);

  final StreamIterator<List<int>> _it;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;
  bool _eof = false;

  int get _avail => _buf.length - _pos;

  Future<bool> _fill(int n) async {
    while (_avail < n) {
      if (_eof || !await _it.moveNext()) {
        _eof = true;
        return false;
      }
      final chunk = _it.current;
      final next = Uint8List(_avail + chunk.length);
      next.setRange(0, _avail, _buf, _pos);
      next.setRange(_avail, next.length, chunk);
      _buf = next;
      _pos = 0;
    }
    return true;
  }

  /// Next pkt-line payload; null for a flush (or delim/response-end) packet.
  /// Throws on `ERR` packets and unexpected end of stream.
  Future<Uint8List?> read() async {
    if (!await _fill(4)) throw GitError('unexpected end of stream from remote');
    final lenStr =
        ascii.decode(_buf.sublist(_pos, _pos + 4), allowInvalid: true);
    final len = int.tryParse(lenStr, radix: 16);
    if (len == null) {
      throw GitError('protocol error: bad pkt-line header "$lenStr"');
    }
    _pos += 4;
    if (len < 4) return null;
    if (!await _fill(len - 4)) {
      throw GitError('unexpected end of stream from remote');
    }
    final data = Uint8List.sublistView(
        Uint8List.fromList(_buf.sublist(_pos, _pos + len - 4)));
    _pos += len - 4;
    if (data.length >= 4 &&
        ascii.decode(data.sublist(0, 4), allowInvalid: true) == 'ERR ') {
      throw GitError(
          'remote error: ${utf8.decode(data.sublist(4), allowMalformed: true).trim()}');
    }
    return data;
  }

  /// Next pkt-line as text without the trailing newline; null on flush.
  Future<String?> readLine() async {
    final d = await read();
    if (d == null) return null;
    var s = utf8.decode(d, allowMalformed: true);
    if (s.endsWith('\n')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// All remaining bytes until end of stream.
  Future<Uint8List> readToEnd() async {
    final out = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(_buf, _pos));
    _buf = Uint8List(0);
    _pos = 0;
    while (!_eof && await _it.moveNext()) {
      out.add(_it.current);
    }
    _eof = true;
    return out.takeBytes();
  }

  /// The next 4 bytes without consuming them (null at end of stream).
  Future<String?> peek4() async {
    if (!await _fill(4)) return null;
    return ascii.decode(_buf.sublist(_pos, _pos + 4), allowInvalid: true);
  }

  /// Reads side-band multiplexed data until flush, returning band 1.
  /// [first] is an already read packet.
  Future<Uint8List> readSideband([Uint8List? first]) async {
    final out = BytesBuilder(copy: false);
    var pending = first;
    while (true) {
      final d = pending ?? await read();
      pending = null;
      if (d == null) break;
      if (d.isEmpty) continue;
      switch (d[0]) {
        case 1:
          out.add(Uint8List.sublistView(d, 1));
        case 2:
          break; // progress
        case 3:
          throw GitError(
              'remote: ${utf8.decode(d.sublist(1), allowMalformed: true).trim()}');
        default:
          throw GitError('protocol error: bad side-band ${d[0]}');
      }
    }
    return out.takeBytes();
  }

  Future<void> cancel() => _it.cancel();
}
