/// A small pure-Dart zlib inflater.
///
/// dart:io's zlib decoder cannot tell how many input bytes a stream used,
/// which is exactly what is needed to walk a packfile received from the
/// network (objects follow each other without lengths). This decoder reports
/// the consumed length.
library;

import 'dart:typed_data';

/// Result of [zlibInflate]: decoded bytes and the number of input bytes the
/// zlib stream occupied (including header and Adler-32 trailer).
class InflateResult {
  InflateResult(this.data, this.consumed);
  final Uint8List data;
  final int consumed;
}

class _Huffman {
  _Huffman(this.counts, this.symbols);
  final Uint16List counts; // number of codes of each length
  final Uint16List symbols; // symbols ordered by code

  factory _Huffman.fromLengths(List<int> lengths, int n) {
    final counts = Uint16List(16);
    for (var i = 0; i < n; i++) {
      counts[lengths[i]]++;
    }
    counts[0] = 0;
    final offs = Uint16List(16);
    for (var i = 1; i < 16; i++) {
      offs[i] = offs[i - 1] + counts[i - 1];
    }
    final symbols = Uint16List(n);
    for (var i = 0; i < n; i++) {
      if (lengths[i] != 0) symbols[offs[lengths[i]]++] = i;
    }
    return _Huffman(counts, symbols);
  }
}

const _lenBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
];
const _lenExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const _distBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, //
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
  16385, 24577,
];
const _distExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];
const _clOrder = [
  16,
  17,
  18,
  0,
  8,
  7,
  9,
  6,
  10,
  5,
  11,
  4,
  12,
  3,
  13,
  2,
  14,
  1,
  15
];

_Huffman? _fixedLit;
_Huffman? _fixedDist;

class _Inflater {
  _Inflater(this.input, this.pos, [int sizeHint = 0])
      : out = Uint8List(sizeHint > 0 ? sizeHint : 1024);

  final Uint8List input;
  int pos;
  int bitBuf = 0;
  int bitCnt = 0;
  Uint8List out;
  int outLen = 0;

  int bits(int need) {
    var val = bitBuf;
    while (bitCnt < need) {
      if (pos >= input.length) {
        throw const FormatException('inflate: unexpected end of data');
      }
      val |= input[pos++] << bitCnt;
      bitCnt += 8;
    }
    bitBuf = val >> need;
    bitCnt -= need;
    return val & ((1 << need) - 1);
  }

  void ensure(int extra) {
    if (outLen + extra <= out.length) return;
    var n = out.length * 2;
    while (n < outLen + extra) {
      n *= 2;
    }
    final grown = Uint8List(n);
    grown.setRange(0, outLen, out);
    out = grown;
  }

  int decode(_Huffman h) {
    var code = 0, first = 0, index = 0;
    for (var len = 1; len < 16; len++) {
      code |= bits(1);
      final count = h.counts[len];
      if (code - count < first) return h.symbols[index + (code - first)];
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw const FormatException('inflate: bad Huffman code');
  }

  void stored() {
    bitBuf = 0;
    bitCnt = 0;
    if (pos + 4 > input.length) {
      throw const FormatException('inflate: truncated');
    }
    final len = input[pos] | (input[pos + 1] << 8);
    final nlen = input[pos + 2] | (input[pos + 3] << 8);
    pos += 4;
    if (len != (~nlen & 0xffff)) {
      throw const FormatException('inflate: bad stored block');
    }
    if (pos + len > input.length) {
      throw const FormatException('inflate: truncated');
    }
    ensure(len);
    out.setRange(outLen, outLen + len, input, pos);
    outLen += len;
    pos += len;
  }

  void codes(_Huffman lit, _Huffman dist) {
    while (true) {
      var sym = decode(lit);
      if (sym < 256) {
        ensure(1);
        out[outLen++] = sym;
      } else if (sym == 256) {
        return;
      } else {
        sym -= 257;
        if (sym >= 29) throw const FormatException('inflate: bad length');
        final len = _lenBase[sym] + bits(_lenExtra[sym]);
        final ds = decode(dist);
        if (ds >= 30) throw const FormatException('inflate: bad distance');
        final d = _distBase[ds] + bits(_distExtra[ds]);
        if (d > outLen) {
          throw const FormatException('inflate: distance too far');
        }
        ensure(len);
        var from = outLen - d;
        for (var i = 0; i < len; i++) {
          out[outLen++] = out[from++];
        }
      }
    }
  }

  void fixed() {
    if (_fixedLit == null) {
      final l = List<int>.filled(288, 0);
      for (var i = 0; i < 144; i++) {
        l[i] = 8;
      }
      for (var i = 144; i < 256; i++) {
        l[i] = 9;
      }
      for (var i = 256; i < 280; i++) {
        l[i] = 7;
      }
      for (var i = 280; i < 288; i++) {
        l[i] = 8;
      }
      _fixedLit = _Huffman.fromLengths(l, 288);
      _fixedDist = _Huffman.fromLengths(List<int>.filled(30, 5), 30);
    }
    codes(_fixedLit!, _fixedDist!);
  }

  void dynamic() {
    final nlen = bits(5) + 257;
    final ndist = bits(5) + 1;
    final ncode = bits(4) + 4;
    final lengths = List<int>.filled(320, 0);
    for (var i = 0; i < ncode; i++) {
      lengths[_clOrder[i]] = bits(3);
    }
    final lencode = _Huffman.fromLengths(lengths, 19);
    var index = 0;
    final all = List<int>.filled(320, 0);
    while (index < nlen + ndist) {
      final sym = decode(lencode);
      if (sym < 16) {
        all[index++] = sym;
      } else {
        var len = 0;
        int rep;
        if (sym == 16) {
          if (index == 0) {
            throw const FormatException('inflate: repeat with no length');
          }
          len = all[index - 1];
          rep = 3 + bits(2);
        } else if (sym == 17) {
          rep = 3 + bits(3);
        } else {
          rep = 11 + bits(7);
        }
        if (index + rep > nlen + ndist) {
          throw const FormatException('inflate: too many lengths');
        }
        while (rep-- > 0) {
          all[index++] = len;
        }
      }
    }
    final lit = _Huffman.fromLengths(all, nlen);
    final dist = _Huffman.fromLengths(all.sublist(nlen), ndist);
    codes(lit, dist);
  }

  void run() {
    var last = 0;
    do {
      last = bits(1);
      final type = bits(2);
      switch (type) {
        case 0:
          stored();
        case 1:
          fixed();
        case 2:
          dynamic();
        default:
          throw const FormatException('inflate: bad block type');
      }
    } while (last == 0);
  }
}

/// Inflates the zlib stream that starts at [offset] in [input].
InflateResult zlibInflate(Uint8List input, [int offset = 0, int sizeHint = 0]) {
  if (offset + 2 > input.length) {
    throw const FormatException('zlib: truncated header');
  }
  final cmf = input[offset], flg = input[offset + 1];
  if ((cmf & 0x0f) != 8 || ((cmf << 8) | flg) % 31 != 0) {
    throw const FormatException('zlib: bad header');
  }
  if (flg & 0x20 != 0) {
    throw const FormatException('zlib: preset dictionary not supported');
  }
  final inf = _Inflater(input, offset + 2, sizeHint);
  inf.run();
  // Discard remaining bits of the current byte; then the Adler-32 trailer.
  final end = inf.pos + 4;
  if (end > input.length) {
    throw const FormatException('zlib: truncated trailer');
  }
  final data = Uint8List.sublistView(inf.out, 0, inf.outLen);
  var a = 1, b = 0;
  for (var i = 0; i < data.length;) {
    final stop = i + 5552 < data.length ? i + 5552 : data.length;
    for (; i < stop; i++) {
      a += data[i];
      b += a;
    }
    a %= 65521;
    b %= 65521;
  }
  final want = (input[inf.pos] << 24) |
      (input[inf.pos + 1] << 16) |
      (input[inf.pos + 2] << 8) |
      input[inf.pos + 3];
  if (((b << 16) | a) != want) {
    throw const FormatException('zlib: Adler-32 mismatch');
  }
  return InflateResult(data, end - offset);
}
