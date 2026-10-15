import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'util.dart';

class IndexEntry {
  IndexEntry({
    required this.path,
    required this.id,
    required this.mode,
    this.ctimeSec = 0,
    this.ctimeNsec = 0,
    this.mtimeSec = 0,
    this.mtimeNsec = 0,
    this.dev = 0,
    this.ino = 0,
    this.uid = 0,
    this.gid = 0,
    this.size = 0,
    this.stage = 0,
  });

  /// Builds an entry with stat data from [stat] of the file on disk.
  factory IndexEntry.fromStat(String path, String id, int mode, FileStat stat) {
    final m = stat.modified.microsecondsSinceEpoch;
    final c = stat.changed.microsecondsSinceEpoch;
    return IndexEntry(
      path: path,
      id: id,
      mode: mode,
      mtimeSec: m ~/ 1000000,
      mtimeNsec: (m % 1000000) * 1000,
      ctimeSec: c ~/ 1000000,
      ctimeNsec: (c % 1000000) * 1000,
      size: stat.size & 0xffffffff,
    );
  }

  final String path;
  final String id;
  final int mode;
  final int ctimeSec, ctimeNsec, mtimeSec, mtimeNsec;
  final int dev, ino, uid, gid, size;
  final int stage;

  String get modeString => mode.toRadixString(8);

  /// Whether the cached stat data still describes [stat] (mtime and size).
  bool statMatches(FileStat stat) {
    final m = stat.modified.microsecondsSinceEpoch;
    return mtimeSec == m ~/ 1000000 &&
        mtimeNsec ~/ 1000 == m % 1000000 &&
        size == (stat.size & 0xffffffff);
  }
}

/// The staging area (`.git/index`), versions 2 and 3 read, version 2 written.
class GitIndex {
  GitIndex(this.entries, [this.fileMtime]);

  /// Entries keyed by path (stage-0 entries; conflict stages are kept in
  /// [conflicts]).
  final Map<String, IndexEntry> entries;
  final List<IndexEntry> conflicts = [];

  /// Modification time of the index file when read, for racy-git checks.
  final DateTime? fileMtime;

  static GitIndex read(String gitDir) {
    final f = File(joinPath(gitDir, 'index'));
    if (!f.existsSync()) return GitIndex({});
    final b = f.readAsBytesSync();
    final idx = parse(b, f.statSync().modified);
    return idx;
  }

  static GitIndex parse(Uint8List b, [DateTime? mtime]) {
    if (b.length < 12 || utf8.decode(b.sublist(0, 4)) != 'DIRC') {
      throw GitError('invalid index file');
    }
    final version = readUint32(b, 4);
    if (version != 2 && version != 3) {
      throw GitError('index version $version is not supported');
    }
    final n = readUint32(b, 8);
    final out = GitIndex({}, mtime);
    var p = 12;
    for (var i = 0; i < n; i++) {
      final start = p;
      int u32() {
        final v = readUint32(b, p);
        p += 4;
        return v;
      }

      final ctimeS = u32(), ctimeN = u32(), mtimeS = u32(), mtimeN = u32();
      final dev = u32(), ino = u32(), mode = u32(), uid = u32(), gid = u32();
      final size = u32();
      final id = toHex(b.sublist(p, p + 20));
      p += 20;
      final flags = (b[p] << 8) | b[p + 1];
      p += 2;
      if (flags & 0x4000 != 0) p += 2; // extended flags (v3)
      final nul = b.indexOf(0, p);
      final path = utf8.decode(b.sublist(p, nul), allowMalformed: true);
      p = nul + 1;
      // Entries are padded with 1-8 NULs to a multiple of 8 bytes.
      while ((p - start) % 8 != 0) {
        p++;
      }
      final e = IndexEntry(
        path: path,
        id: id,
        mode: mode,
        ctimeSec: ctimeS,
        ctimeNsec: ctimeN,
        mtimeSec: mtimeS,
        mtimeNsec: mtimeN,
        dev: dev,
        ino: ino,
        uid: uid,
        gid: gid,
        size: size,
        stage: (flags >> 12) & 3,
      );
      if (e.stage == 0) {
        out.entries[path] = e;
      } else {
        out.conflicts.add(e);
      }
    }
    return out;
  }

  Uint8List serialize() {
    final all = [...entries.values, ...conflicts]..sort((a, c) {
        final d = comparePaths(a.path, c.path);
        return d != 0 ? d : a.stage - c.stage;
      });
    final b = BytesBuilder(copy: false)..add(ascii.encode('DIRC'));
    writeUint32(b, 2);
    writeUint32(b, all.length);
    for (final e in all) {
      final start = b.length;
      for (final v in [
        e.ctimeSec, e.ctimeNsec, e.mtimeSec, e.mtimeNsec, e.dev, e.ino, //
        e.mode, e.uid, e.gid, e.size,
      ]) {
        writeUint32(b, v & 0xffffffff);
      }
      b.add(fromHex(e.id));
      final name = utf8.encode(e.path);
      final len = name.length < 0xfff ? name.length : 0xfff;
      writeUint16(b, (e.stage << 12) | len);
      b.add(name);
      b.addByte(0);
      while ((b.length - start) % 8 != 0) {
        b.addByte(0);
      }
    }
    final body = b.takeBytes();
    return (BytesBuilder(copy: false)
          ..add(body)
          ..add(sha1Bytes(body)))
        .takeBytes();
  }

  void write(String gitDir) {
    final path = joinPath(gitDir, 'index');
    final lock = File('$path.lock');
    try {
      lock.createSync(exclusive: true);
    } on FileSystemException {
      throw GitError('cannot lock index (${lock.path} exists)');
    }
    try {
      lock.writeAsBytesSync(serialize(), flush: true);
      lock.renameSync(path);
    } catch (_) {
      if (lock.existsSync()) lock.deleteSync();
      rethrow;
    }
  }
}
