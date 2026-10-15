import 'dart:io';
import 'dart:typed_data';

import 'inflate.dart';
import 'objects.dart';
import 'util.dart';
import 'hash.dart';

const _typeOfsDelta = 6;
const _typeRefDelta = 7;

/// A `.idx` version 2 file loaded into memory.
class PackIndex {
  PackIndex._(this.count, this._fanout, this._ids, this._offsets, this._n);

  factory PackIndex.parse(Uint8List b, ObjectFormat format) {
    final size = format.size;
    if (b.length < 8 + 1024 ||
        readUint32(b, 0) != 0xff744f63 ||
        readUint32(b, 4) != 2) {
      throw GitError('unsupported pack index (only version 2 is supported)');
    }
    final fanout = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      fanout[i] = readUint32(b, 8 + i * 4);
    }
    final n = fanout[255];
    final idsStart = 8 + 1024;
    final ids = Uint8List.sublistView(b, idsStart, idsStart + n * size);
    final offStart = idsStart + n * size + n * 4;
    final large = offStart + n * 4;
    final offsets = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final v = readUint32(b, offStart + i * 4);
      if (v & 0x80000000 != 0) {
        final j = large + (v & 0x7fffffff) * 8;
        offsets[i] = (readUint32(b, j) << 32) | readUint32(b, j + 4);
      } else {
        offsets[i] = v;
      }
    }
    return PackIndex._(n, fanout, ids, offsets, size);
  }

  final int count;
  final Uint32List _fanout;
  final Uint8List _ids;
  final List<int> _offsets;
  final int _n; // id size in bytes
  List<int>? _sortedOffsets;

  String idAt(int i) => toHex(Uint8List.sublistView(_ids, i * _n, i * _n + _n));
  int offsetAt(int i) => _offsets[i];

  /// Index of [id] in this pack or -1.
  int find(String id) {
    final target = fromHex(id);
    final first = target[0];
    var lo = first == 0 ? 0 : _fanout[first - 1];
    var hi = _fanout[first];
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      var c = 0;
      final base = mid * _n;
      for (var k = 0; k < _n && c == 0; k++) {
        c = _ids[base + k] - target[k];
      }
      if (c == 0) return mid;
      if (c < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return -1;
  }

  /// Offset of the object following [offset] in the pack (or -1 if last).
  int nextOffset(int offset) {
    final s = _sortedOffsets ??= ([..._offsets]..sort());
    var lo = 0, hi = s.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (s[mid] <= offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < s.length ? s[lo] : -1;
  }
}

/// Reads objects from a `.pack` using its `.idx`.
class PackFile {
  PackFile(this.idxPath, this.packPath, this.db);

  final String idxPath;
  final String packPath;
  final ObjectDatabase db;
  PackIndex? _index;
  RandomAccessFile? _raf;
  int _length = 0;
  final _baseCache = <int, GitObject>{};

  PackIndex get index =>
      _index ??= PackIndex.parse(File(idxPath).readAsBytesSync(), db.format);

  RandomAccessFile get _file {
    var f = _raf;
    if (f == null) {
      f = _raf = File(packPath).openSync();
      _length = f.lengthSync();
    }
    return f;
  }

  void close() {
    _raf?.closeSync();
    _raf = null;
  }

  GitObject? read(String id) {
    final i = index.find(id);
    if (i < 0) return null;
    return _readAt(index.offsetAt(i), 0);
  }

  Uint8List _bytes(int offset, int length) {
    final f = _file;
    f.setPositionSync(offset);
    return f.readSync(length);
  }

  GitObject _readAt(int offset, int depth) {
    final cached = _baseCache[offset];
    if (cached != null) return cached;
    if (depth > 10000) throw GitError('delta chain too long');
    _file;
    var end = index.nextOffset(offset);
    if (end < 0) end = _length - db.format.size;
    final raw = _bytes(offset, end - offset);
    var p = 0;
    var c = raw[p++];
    final type = (c >> 4) & 7;
    var size = c & 15;
    var shift = 4;
    while (c & 0x80 != 0) {
      c = raw[p++];
      size |= (c & 0x7f) << shift;
      shift += 7;
    }
    GitObject result;
    if (type == _typeOfsDelta) {
      c = raw[p++];
      var rel = c & 0x7f;
      while (c & 0x80 != 0) {
        c = raw[p++];
        rel = ((rel + 1) << 7) | (c & 0x7f);
      }
      final delta = inflateKnown(Uint8List.sublistView(raw, p));
      final base = _readAt(offset - rel, depth + 1);
      result = GitObject(base.type, applyDelta(base.data, delta));
    } else if (type == _typeRefDelta) {
      final baseId = toHex(raw.sublist(p, p + db.format.size));
      p += db.format.size;
      final delta = inflateKnown(Uint8List.sublistView(raw, p));
      final bi = index.find(baseId);
      final base =
          bi >= 0 ? _readAt(index.offsetAt(bi), depth + 1) : db.read(baseId);
      result = GitObject(base.type, applyDelta(base.data, delta));
    } else {
      result = GitObject(ObjectType.fromCode(type),
          inflateKnown(Uint8List.sublistView(raw, p)));
      if (result.data.length != size) {
        throw GitError('pack object size mismatch in $packPath');
      }
    }
    if (depth > 0) {
      if (_baseCache.length > 256) _baseCache.clear();
      _baseCache[offset] = result;
    }
    return result;
  }
}

/// Applies a Git binary delta to [base].
Uint8List applyDelta(Uint8List base, Uint8List delta) {
  var p = 0;
  int varint() {
    var v = 0, shift = 0, c = 0;
    do {
      c = delta[p++];
      v |= (c & 0x7f) << shift;
      shift += 7;
    } while (c & 0x80 != 0);
    return v;
  }

  final srcSize = varint();
  if (srcSize != base.length) throw GitError('delta base size mismatch');
  final dstSize = varint();
  final out = Uint8List(dstSize);
  var o = 0;
  while (p < delta.length) {
    final op = delta[p++];
    if (op & 0x80 != 0) {
      var off = 0, len = 0;
      if (op & 0x01 != 0) off |= delta[p++];
      if (op & 0x02 != 0) off |= delta[p++] << 8;
      if (op & 0x04 != 0) off |= delta[p++] << 16;
      if (op & 0x08 != 0) off |= delta[p++] << 24;
      if (op & 0x10 != 0) len |= delta[p++];
      if (op & 0x20 != 0) len |= delta[p++] << 8;
      if (op & 0x40 != 0) len |= delta[p++] << 16;
      if (len == 0) len = 0x10000;
      if (off + len > base.length || o + len > dstSize) {
        throw GitError('bad delta copy');
      }
      out.setRange(o, o + len, base, off);
      o += len;
    } else if (op != 0) {
      if (o + op > dstSize || p + op > delta.length) {
        throw GitError('bad delta insert');
      }
      out.setRange(o, o + op, delta, p);
      o += op;
      p += op;
    } else {
      throw GitError('bad delta opcode');
    }
  }
  if (o != dstSize) throw GitError('delta result size mismatch');
  return out;
}

// ---------------------------------------------------------------------------
// Writing packs

/// Builds an undeltified version 2 pack from objects.
Uint8List buildPack(Iterable<GitObject> objects, ObjectFormat format) {
  final list = objects.toList();
  final b = BytesBuilder(copy: false)
    ..add([0x50, 0x41, 0x43, 0x4b, 0, 0, 0, 2]);
  writeUint32(b, list.length);
  for (final o in list) {
    var size = o.data.length;
    var c = (o.type.code << 4) | (size & 15);
    size >>= 4;
    while (size > 0) {
      b.addByte(c | 0x80);
      c = size & 0x7f;
      size >>= 7;
    }
    b.addByte(c);
    b.add(deflate(o.data));
  }
  final body = b.takeBytes();
  return (BytesBuilder(copy: false)
        ..add(body)
        ..add(format.hash(body)))
      .takeBytes();
}

class _PackEntry {
  _PackEntry(this.offset, this.type, this.data, this.crc);
  final int offset;
  int type;
  Uint8List data;
  final int crc;
  int baseOffset = -1;
  String? baseId;
  String? id;
}

/// Parses a received pack, resolves deltas and stores the objects.
///
/// Packs with fewer than [unpackLimit] objects are exploded into loose
/// objects (like Git's `transfer.unpackLimit`); larger ones are written as a
/// `.pack` plus a version 2 `.idx`. Returns the number of objects.
int storePack(ObjectDatabase db, Uint8List pack, {int unpackLimit = 100}) {
  if (pack.length < 12 + db.format.size ||
      pack[0] != 0x50 ||
      pack[1] != 0x41 ||
      pack[2] != 0x43 ||
      pack[3] != 0x4b) {
    throw GitError('invalid pack data');
  }
  final version = readUint32(pack, 4);
  if (version != 2 && version != 3) {
    throw GitError('unsupported pack version $version');
  }
  final count = readUint32(pack, 8);
  final format = db.format, n = format.size;
  final trailer = toHex(Uint8List.sublistView(pack, pack.length - n));
  if (format.hashHex(Uint8List.sublistView(pack, 0, pack.length - n)) !=
      trailer) {
    throw GitError('pack checksum mismatch');
  }

  final entries = <_PackEntry>[];
  final byOffset = <int, _PackEntry>{};
  var p = 12;
  for (var i = 0; i < count; i++) {
    final start = p;
    var c = pack[p++];
    final type = (c >> 4) & 7;
    var size = c & 15;
    var shift = 4;
    while (c & 0x80 != 0) {
      c = pack[p++];
      size |= (c & 0x7f) << shift;
      shift += 7;
    }
    var baseOffset = -1;
    String? baseId;
    if (type == _typeOfsDelta) {
      c = pack[p++];
      var rel = c & 0x7f;
      while (c & 0x80 != 0) {
        c = pack[p++];
        rel = ((rel + 1) << 7) | (c & 0x7f);
      }
      baseOffset = start - rel;
    } else if (type == _typeRefDelta) {
      baseId = toHex(pack.sublist(p, p + n));
      p += n;
    } else if (type < 1 || type > 4) {
      throw GitError('bad object type $type in pack');
    }
    final inf = zlibInflate(pack, p, size);
    p += inf.consumed;
    final e = _PackEntry(start, type, inf.data, crc32(pack, start, p))
      ..baseOffset = baseOffset
      ..baseId = baseId;
    entries.add(e);
    byOffset[start] = e;
  }
  if (p != pack.length - n) throw GitError('trailing garbage in pack');

  final byId = <String, _PackEntry>{};
  for (final e in entries) {
    if (e.type <= 4) {
      e.id = hashObject(ObjectType.fromCode(e.type), e.data, format);
      byId[e.id!] = e;
    }
  }
  var thin = false;
  // Resolve deltas iteratively (a base may itself be a delta).
  GitObject resolve(_PackEntry e) {
    final chain = <_PackEntry>[];
    var cur = e;
    GitObject? base;
    while (cur.type > 4) {
      chain.add(cur);
      _PackEntry? next;
      if (cur.type == _typeOfsDelta) {
        next = byOffset[cur.baseOffset];
        if (next == null) throw GitError('delta base missing in pack');
      } else {
        next = byId[cur.baseId];
        if (next == null) {
          final o = db.tryRead(cur.baseId!);
          if (o == null) throw GitError('delta base ${cur.baseId} not found');
          thin = true;
          base = o;
          break;
        }
      }
      cur = next;
    }
    base ??= GitObject(ObjectType.fromCode(cur.type), cur.data);
    for (final d in chain.reversed) {
      final data = applyDelta(base!.data, d.data);
      d
        ..type = base.type.code
        ..data = data
        ..id = hashObject(base.type, data, format);
      byId[d.id!] = d;
      base = GitObject(base.type, data);
    }
    return base!;
  }

  bool canResolve(_PackEntry e) {
    var cur = e;
    while (cur.type > 4) {
      if (cur.type == _typeOfsDelta) {
        cur = byOffset[cur.baseOffset]!;
      } else {
        final next = byId[cur.baseId];
        if (next == null) return db.has(cur.baseId!);
        cur = next;
      }
    }
    return true;
  }

  // Ref-deltas may point at objects resolved later; loop until stable.
  var pending = entries.where((e) => e.type > 4).toList();
  while (pending.isNotEmpty) {
    final before = pending.length;
    final still = <_PackEntry>[];
    for (final e in pending) {
      if (e.type <= 4) continue;
      if (!canResolve(e)) {
        still.add(e);
        continue;
      }
      resolve(e);
    }
    pending = still;
    if (pending.length == before) throw GitError('unresolvable deltas in pack');
  }

  if (count < unpackLimit || thin) {
    for (final e in entries) {
      db.write(ObjectType.fromCode(e.type), e.data);
    }
    return count;
  }

  // Write .pack and .idx.
  final sorted = [...entries]..sort((a, b) => a.id!.compareTo(b.id!));
  final idx = BytesBuilder(copy: false)
    ..add([0xff, 0x74, 0x4f, 0x63, 0, 0, 0, 2]);
  final fan = List<int>.filled(256, 0);
  for (final e in sorted) {
    fan[int.parse(e.id!.substring(0, 2), radix: 16)]++;
  }
  var acc = 0;
  for (var i = 0; i < 256; i++) {
    acc += fan[i];
    writeUint32(idx, acc);
  }
  for (final e in sorted) {
    idx.add(fromHex(e.id!));
  }
  for (final e in sorted) {
    writeUint32(idx, e.crc);
  }
  final large = <int>[];
  for (final e in sorted) {
    if (e.offset >= 0x80000000) {
      writeUint32(idx, 0x80000000 | large.length);
      large.add(e.offset);
    } else {
      writeUint32(idx, e.offset);
    }
  }
  for (final o in large) {
    writeUint32(idx, o >> 32);
    writeUint32(idx, o & 0xffffffff);
  }
  idx.add(fromHex(trailer));
  final idxBody = idx.takeBytes();
  final idxBytes = (BytesBuilder(copy: false)
        ..add(idxBody)
        ..add(format.hash(idxBody)))
      .takeBytes();
  final base = joinPath(db.objectsDir, 'pack/pack-$trailer');
  Directory(joinPath(db.objectsDir, 'pack')).createSync(recursive: true);
  writeFileAtomic('$base.pack', pack);
  writeFileAtomic('$base.idx', idxBytes);
  db.rescan();
  return count;
}
