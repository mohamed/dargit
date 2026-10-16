import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Error raised by every dargit operation.
class GitException implements Exception {
  GitException(this.operation, this.message);

  /// The operation that failed, e.g. `clone`, `sync`, `commit`.
  final String operation;

  /// Human readable description of the failure.
  final String message;

  @override
  String toString() => 'GitException($operation): $message';
}

/// Internal error with no operation yet; [Git] wraps it in a
/// [GitException] carrying the operation name.
class GitError implements Exception {
  GitError(this.message);
  final String message;
  @override
  String toString() => message;
}

String toHex(List<int> bytes) {
  const digits = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.writeCharCode(digits.codeUnitAt(b >> 4));
    sb.writeCharCode(digits.codeUnitAt(b & 15));
  }
  return sb.toString();
}

Uint8List fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int crc32(Uint8List data, int start, int end) {
  var c = 0xffffffff;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ data[i]) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

final ZLibCodec _zlib = ZLibCodec(level: 1);
Uint8List deflate(List<int> data) => Uint8List.fromList(_zlib.encode(data));
Uint8List inflateKnown(List<int> data) =>
    Uint8List.fromList(_zlib.decode(data));

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

int readUint32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

void writeUint32(BytesBuilder b, int v) {
  b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
}

void writeUint16(BytesBuilder b, int v) {
  b.add([(v >> 8) & 0xff, v & 0xff]);
}

/// Lexicographic comparison of byte strings (as Git sorts paths).
int compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}

/// Compares paths the way Git orders index entries (bytewise on UTF-8).
int comparePaths(String a, String b) {
  // Fast path for ASCII strings: code unit order equals byte order.
  return compareBytes(utf8.encode(a), utf8.encode(b));
}

/// Writes [data] atomically next to [path] and renames it into place.
void writeFileAtomic(String path, List<int> data) {
  final tmp = File('$path.tmp${DateTime.now().microsecondsSinceEpoch}');
  tmp.parent.createSync(recursive: true);
  tmp.writeAsBytesSync(data, flush: false);
  tmp.renameSync(path);
}

/// Joins a repository-relative `/` path onto [dir] using the platform
/// separator.
String joinPath(String dir, String rel) {
  final sep = Platform.pathSeparator;
  final r = sep == '/' ? rel : rel.replaceAll('/', sep);
  if (dir.endsWith(sep)) return '$dir$r';
  return '$dir$sep$r';
}

/// UTF-8 text from bytes that may not be valid UTF-8.
String lenient(List<int> b) => utf8.decode(b, allowMalformed: true);
