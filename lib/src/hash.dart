import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// A repository's object format (`extensions.objectFormat`): the hash that
/// names objects and checksums packs, indexes and pack indexes. SHA-1 is
/// git's historical default; SHA-256 is the format of Git 3.
enum ObjectFormat {
  sha1('sha1', 20),
  sha256('sha256', 32);

  const ObjectFormat(this.name, this.size);

  /// Name used in config and in the protocol's `object-format` capability.
  final String name;

  /// Length of a binary object id (and of every checksum) in bytes.
  final int size;

  /// Length of a hex object id.
  int get hexLength => size * 2;

  /// The all-zero id (a missing ref in the protocol and in reflogs).
  String get zeroId => '0' * hexLength;

  crypto.Hash get _hash => this == sha1 ? crypto.sha1 : crypto.sha256;

  Uint8List hash(List<int> data) =>
      Uint8List.fromList(_hash.convert(data).bytes);

  String hashHex(List<int> data) => _hash.convert(data).toString();

  bool isId(String s) => s.length == hexLength && isObjectId(s);

  /// The format named [name] (`null` means SHA-1, as in git).
  static ObjectFormat parse(String? name) => switch (name?.toLowerCase()) {
        null || 'sha1' => sha1,
        'sha256' => sha256,
        _ => throw FormatException('unknown object format "$name"'),
      };
}

final _hexRe = RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$');

/// Whether [s] is a full hex object id in any supported format.
bool isObjectId(String s) => _hexRe.hasMatch(s);

/// Whether [s] is an all-zero object id (any format).
bool isZeroId(String s) => isObjectId(s) && !s.contains(RegExp('[^0]'));
