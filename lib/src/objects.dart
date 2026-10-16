import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pack.dart';
import 'util.dart';
import 'hash.dart';

enum ObjectType {
  commit(1, 'commit'),
  tree(2, 'tree'),
  blob(3, 'blob'),
  tag(4, 'tag');

  const ObjectType(this.code, this.label);
  final int code;
  final String label;

  static ObjectType fromCode(int code) => switch (code) {
        1 => commit,
        2 => tree,
        3 => blob,
        4 => tag,
        _ => throw GitError('unknown object type $code'),
      };

  static ObjectType fromLabel(String s) => switch (s) {
        'commit' => commit,
        'tree' => tree,
        'blob' => blob,
        'tag' => tag,
        _ => throw GitError('unknown object type $s'),
      };
}

class GitObject {
  GitObject(this.type, this.data);
  final ObjectType type;
  final Uint8List data;
}

/// Raw object bytes as hashed by Git: `<type> <size>\0<data>`.
Uint8List objectBytes(ObjectType type, List<int> data) {
  final b = BytesBuilder(copy: false)
    ..add(ascii.encode('${type.label} ${data.length}'))
    ..addByte(0)
    ..add(data);
  return b.takeBytes();
}

String hashObject(ObjectType type, List<int> data, ObjectFormat format) =>
    format.hashHex(objectBytes(type, data));

// ---------------------------------------------------------------------------
// Trees

const modeTree = '40000';
const modeFile = '100644';
const modeExec = '100755';
const modeLink = '120000';
const modeGitlink = '160000';

class TreeEntry {
  TreeEntry(this.mode, this.name, this.id);
  final String mode;
  final String name;
  final String id;
  bool get isTree => mode == modeTree;
}

List<TreeEntry> parseTree(Uint8List data, ObjectFormat format) {
  final n = format.size;
  final out = <TreeEntry>[];
  var i = 0;
  while (i < data.length) {
    final sp = data.indexOf(0x20, i);
    final nul = data.indexOf(0, sp);
    if (sp < 0 || nul < 0 || nul + 1 + n > data.length) {
      throw GitError('corrupt tree object');
    }
    final mode = ascii.decode(data.sublist(i, sp));
    final name = utf8.decode(data.sublist(sp + 1, nul), allowMalformed: true);
    final id = toHex(data.sublist(nul + 1, nul + 1 + n));
    out.add(TreeEntry(mode == '040000' ? modeTree : mode, name, id));
    i = nul + 1 + n;
  }
  return out;
}

int _treeSortCompare(TreeEntry a, TreeEntry b) {
  final an = utf8.encode(a.isTree ? '${a.name}/' : a.name);
  final bn = utf8.encode(b.isTree ? '${b.name}/' : b.name);
  return compareBytes(an, bn);
}

Uint8List serializeTree(List<TreeEntry> entries) {
  final sorted = [...entries]..sort(_treeSortCompare);
  final b = BytesBuilder(copy: false);
  for (final e in sorted) {
    b.add(ascii.encode(e.mode));
    b.addByte(0x20);
    b.add(utf8.encode(e.name));
    b.addByte(0);
    b.add(fromHex(e.id));
  }
  return b.takeBytes();
}

// ---------------------------------------------------------------------------
// Commits

class Signature {
  Signature(this.name, this.email, this.time, this.tzOffsetMinutes);

  factory Signature.now(String name, String email) {
    final now = DateTime.now();
    return Signature(name, email, now, now.timeZoneOffset.inMinutes);
  }

  final String name;
  final String email;
  final DateTime time;
  final int tzOffsetMinutes;

  static Signature parse(String s) {
    final lt = s.lastIndexOf('<');
    final gt = s.lastIndexOf('>');
    if (lt < 0 || gt < lt) return Signature(s, '', DateTime.utc(1970), 0);
    final name = s.substring(0, lt).trim();
    final email = s.substring(lt + 1, gt);
    final rest = s.substring(gt + 1).trim().split(' ');
    final secs = rest.isNotEmpty ? int.tryParse(rest[0]) ?? 0 : 0;
    var tz = 0;
    if (rest.length > 1 && rest[1].length == 5) {
      final sign = rest[1][0] == '-' ? -1 : 1;
      final h = int.tryParse(rest[1].substring(1, 3)) ?? 0;
      final m = int.tryParse(rest[1].substring(3, 5)) ?? 0;
      tz = sign * (h * 60 + m);
    }
    return Signature(name, email,
        DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true), tz);
  }

  String format() {
    final secs = time.millisecondsSinceEpoch ~/ 1000;
    final sign = tzOffsetMinutes < 0 ? '-' : '+';
    final a = tzOffsetMinutes.abs();
    final tz = '$sign${(a ~/ 60).toString().padLeft(2, '0')}'
        '${(a % 60).toString().padLeft(2, '0')}';
    return '$name <$email> $secs $tz';
  }
}

class Commit {
  Commit({
    required this.tree,
    required this.parents,
    required this.author,
    required this.committer,
    required this.message,
    this.extraHeaders = const [],
  });

  final String tree;
  final List<String> parents;
  final Signature author;
  final Signature committer;
  final String message;

  /// Headers other than tree/parent/author/committer (e.g. gpgsig), kept as
  /// raw `key value` text; dropped when a commit is rewritten.
  final List<String> extraHeaders;

  static Commit parse(Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);
    final split = text.indexOf('\n\n');
    final head = split < 0 ? text : text.substring(0, split);
    final message = split < 0 ? '' : text.substring(split + 2);
    String? tree;
    final parents = <String>[];
    Signature? author, committer;
    final extra = <String>[];
    for (final line in head.split('\n')) {
      if (line.startsWith(' ')) {
        if (extra.isNotEmpty) extra[extra.length - 1] += '\n$line';
        continue;
      }
      final sp = line.indexOf(' ');
      if (sp < 0) continue;
      final key = line.substring(0, sp), value = line.substring(sp + 1);
      switch (key) {
        case 'tree':
          tree = value;
        case 'parent':
          parents.add(value);
        case 'author':
          author = Signature.parse(value);
        case 'committer':
          committer = Signature.parse(value);
        default:
          extra.add(line);
      }
    }
    if (tree == null) throw GitError('corrupt commit: no tree');
    author ??= Signature('', '', DateTime.utc(1970), 0);
    return Commit(
      tree: tree,
      parents: parents,
      author: author,
      committer: committer ?? author,
      message: message,
      extraHeaders: extra,
    );
  }

  Uint8List serialize() {
    final sb = StringBuffer()..write('tree $tree\n');
    for (final p in parents) {
      sb.write('parent $p\n');
    }
    sb
      ..write('author ${author.format()}\n')
      ..write('committer ${committer.format()}\n')
      ..write('\n')
      ..write(message);
    return utf8Bytes(sb.toString());
  }
}

// ---------------------------------------------------------------------------
// Object database

class ObjectDatabase {
  ObjectDatabase(this.objectsDir, [this.format = ObjectFormat.sha1]);

  /// The repository's object format.
  final ObjectFormat format;

  final String objectsDir;
  List<PackFile>? _packs;
  final _cache = <String, GitObject>{};
  static const _cacheLimit = 2048;

  List<PackFile> get packs => _packs ??= _loadPacks();

  List<PackFile> _loadPacks() {
    final dir = Directory(joinPath(objectsDir, 'pack'));
    if (!dir.existsSync()) return [];
    final out = <PackFile>[];
    for (final f in dir.listSync()) {
      if (f is File && f.path.endsWith('.idx')) {
        final pack = '${f.path.substring(0, f.path.length - 4)}.pack';
        if (File(pack).existsSync()) out.add(PackFile(f.path, pack, this));
      }
    }
    return out;
  }

  /// Forgets the known packs so new ones are found.
  void rescan() {
    close();
    _packs = null;
  }

  void close() {
    for (final p in _packs ?? const <PackFile>[]) {
      p.close();
    }
    _packs = null;
  }

  String _loosePath(String id) =>
      joinPath(objectsDir, '${id.substring(0, 2)}/${id.substring(2)}');

  bool has(String id) {
    if (_cache.containsKey(id)) return true;
    if (File(_loosePath(id)).existsSync()) return true;
    for (final p in packs) {
      if (p.index.find(id) >= 0) return true;
    }
    return false;
  }

  /// Resolves an abbreviated id; null when unknown or ambiguous.
  String? resolvePrefix(String prefix) {
    final found = <String>{};
    final dir = Directory(joinPath(objectsDir, prefix.substring(0, 2)));
    if (dir.existsSync()) {
      for (final f in dir.listSync()) {
        final name =
            f.path.substring(f.path.lastIndexOf(Platform.pathSeparator) + 1);
        final id = '${prefix.substring(0, 2)}$name';
        if (format.isId(id) && id.startsWith(prefix)) found.add(id);
      }
    }
    for (final p in packs) {
      for (var i = 0; i < p.index.count; i++) {
        final id = p.index.idAt(i);
        if (id.startsWith(prefix)) found.add(id);
      }
    }
    return found.length == 1 ? found.first : null;
  }

  GitObject? tryRead(String id) {
    final cached = _cache[id];
    if (cached != null) return cached;
    GitObject? obj;
    final f = File(_loosePath(id));
    if (f.existsSync()) {
      obj = _parseLoose(inflateKnown(f.readAsBytesSync()), id);
    } else {
      for (final p in packs) {
        obj = p.read(id);
        if (obj != null) break;
      }
    }
    if (obj != null && obj.type != ObjectType.blob) {
      if (_cache.length >= _cacheLimit) _cache.clear();
      _cache[id] = obj;
    }
    return obj;
  }

  GitObject read(String id) {
    final o = tryRead(id);
    if (o == null) throw GitError('object $id not found');
    return o;
  }

  GitObject _parseLoose(Uint8List raw, String id) {
    final nul = raw.indexOf(0);
    final header = ascii.decode(raw.sublist(0, nul));
    final sp = header.indexOf(' ');
    final type = ObjectType.fromLabel(header.substring(0, sp));
    return GitObject(type, Uint8List.sublistView(raw, nul + 1));
  }

  String write(ObjectType type, List<int> data) {
    final raw = objectBytes(type, data);
    final id = format.hashHex(raw);
    if (!has(id)) {
      final path = _loosePath(id);
      final f = File(path);
      f.parent.createSync(recursive: true);
      writeFileAtomic(path, deflate(raw));
    }
    return id;
  }

  Commit readCommit(String id) {
    final o = read(id);
    if (o.type != ObjectType.commit) throw GitError('$id is not a commit');
    return Commit.parse(o.data);
  }

  List<TreeEntry> readTree(String id) {
    final o = read(id);
    if (o.type != ObjectType.tree) throw GitError('$id is not a tree');
    return parseTree(o.data, format);
  }

  /// Flattens a tree into `path -> (mode, id)` for all blobs/links/gitlinks.
  Map<String, TreeEntry> flattenTree(String treeId, [String prefix = '']) {
    final out = <String, TreeEntry>{};
    void walk(String id, String pre) {
      for (final e in readTree(id)) {
        final p = pre.isEmpty ? e.name : '$pre/${e.name}';
        if (e.isTree) {
          walk(e.id, p);
        } else {
          out[p] = TreeEntry(e.mode, p, e.id);
        }
      }
    }

    walk(treeId, prefix);
    return out;
  }

  /// Writes nested trees for a flat `path -> entry` map; returns the root id.
  String writeTreeFromFlat(Map<String, TreeEntry> flat) {
    final root = _DirNode();
    for (final e in flat.entries) {
      final parts = e.key.split('/');
      var node = root;
      for (var i = 0; i < parts.length - 1; i++) {
        node = node.dirs.putIfAbsent(parts[i], _DirNode.new);
      }
      node.files[parts.last] = e.value;
    }
    String writeNode(_DirNode n) {
      final entries = <TreeEntry>[];
      n.dirs.forEach((name, child) {
        if (child.isEmpty) return;
        entries.add(TreeEntry(modeTree, name, writeNode(child)));
      });
      n.files.forEach((name, e) => entries.add(TreeEntry(e.mode, name, e.id)));
      return write(ObjectType.tree, serializeTree(entries));
    }

    return writeNode(root);
  }

  /// Returns the entry for [path] inside tree [treeId], or null.
  TreeEntry? lookupPath(String treeId, String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    var current = treeId;
    for (var i = 0; i < parts.length; i++) {
      final entries = readTree(current);
      TreeEntry? found;
      for (final e in entries) {
        if (e.name == parts[i]) {
          found = e;
          break;
        }
      }
      if (found == null) return null;
      if (i == parts.length - 1) return found;
      if (!found.isTree) return null;
      current = found.id;
    }
    return null;
  }
}

class _DirNode {
  final dirs = <String, _DirNode>{};
  final files = <String, TreeEntry>{};
  bool get isEmpty => files.isEmpty && dirs.values.every((d) => d.isEmpty);
}
