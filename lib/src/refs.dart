import 'dart:io';

import 'util.dart';
import 'hash.dart';

/// Loose refs, packed-refs and symbolic refs (HEAD).
class RefStore {
  RefStore(this.gitDir);

  final String gitDir;

  File _loose(String name) => File(joinPath(gitDir, name));
  File get _packedFile => File(joinPath(gitDir, 'packed-refs'));

  Map<String, String> _readPacked() {
    final f = _packedFile;
    final out = <String, String>{};
    if (!f.existsSync()) return out;
    for (final line in f.readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#') || line.startsWith('^')) {
        continue;
      }
      final sp = line.indexOf(' ');
      if (sp > 0 && isObjectId(line.substring(0, sp))) {
        out[line.substring(sp + 1)] = line.substring(0, sp);
      }
    }
    return out;
  }

  /// Raw content of a ref: an object id or `ref: <target>`; null if missing.
  String? readRaw(String name) {
    final f = _loose(name);
    if (f.existsSync() && FileSystemEntity.isFileSync(f.path)) {
      return f.readAsStringSync().trim();
    }
    return _readPacked()[name];
  }

  /// Target of symbolic ref [name] (e.g. HEAD -> refs/heads/main), or null.
  String? symbolicTarget(String name) {
    final raw = readRaw(name);
    if (raw != null && raw.startsWith('ref: ')) return raw.substring(5).trim();
    return null;
  }

  /// Resolves [name] (following symbolic refs) to an object id, or null.
  String? resolve(String name) {
    var current = name;
    for (var depth = 0; depth < 10; depth++) {
      final raw = readRaw(current);
      if (raw == null) return null;
      if (raw.startsWith('ref: ')) {
        current = raw.substring(5).trim();
        continue;
      }
      return isObjectId(raw) ? raw : null;
    }
    throw GitError('symbolic ref loop at $name');
  }

  void _writeLocked(String name, String content) {
    final f = _loose(name);
    f.parent.createSync(recursive: true);
    final lock = File('${f.path}.lock');
    try {
      lock.createSync(exclusive: true);
    } on FileSystemException {
      throw GitError('cannot lock ref $name (${lock.path} exists)');
    }
    try {
      lock.writeAsStringSync(content, flush: true);
      lock.renameSync(f.path);
    } catch (_) {
      if (lock.existsSync()) lock.deleteSync();
      rethrow;
    }
  }

  void update(String name, String id) => _writeLocked(name, '$id\n');

  void setSymbolic(String name, String target) =>
      _writeLocked(name, 'ref: $target\n');

  void delete(String name) {
    final f = _loose(name);
    if (f.existsSync()) f.deleteSync();
    final packed = _readPacked();
    if (packed.containsKey(name)) {
      final lines = _packedFile.readAsLinesSync();
      final out = StringBuffer();
      var skipPeeled = false;
      for (final line in lines) {
        if (line.startsWith('^')) {
          if (!skipPeeled) out.writeln(line);
          continue;
        }
        skipPeeled = line.length > 41 && line.substring(41) == name;
        if (!skipPeeled) out.writeln(line);
      }
      writeFileAtomic(_packedFile.path, utf8Bytes(out.toString()));
    }
  }

  /// All refs under [prefix] (e.g. `refs/remotes/origin/`) -> object id.
  Map<String, String> list(String prefix) {
    final out = <String, String>{};
    _readPacked().forEach((k, v) {
      if (k.startsWith(prefix)) out[k] = v;
    });
    final dir = Directory(joinPath(gitDir, prefix));
    if (dir.existsSync()) {
      final base = Directory(gitDir).absolute.path;
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is! File || e.path.endsWith('.lock')) continue;
        var rel = e.absolute.path.substring(base.length);
        rel = rel.replaceAll(Platform.pathSeparator, '/');
        while (rel.startsWith('/')) {
          rel = rel.substring(1);
        }
        final v = e.readAsStringSync().trim();
        if (isObjectId(v)) out[rel] = v;
      }
    }
    return out;
  }
}
