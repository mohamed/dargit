import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'hash.dart';
import 'ignore.dart';
import 'index.dart';
import 'objects.dart';
import 'refs.dart';
import 'util.dart';

/// A file found in the working tree.
class WorkFile {
  WorkFile(this.path, this.mode, this.stat);
  final String path;
  final String mode;
  final FileStat stat;
}

class Repository {
  Repository._(this.gitDir, this.workDir)
      : commonDir = _commonDir(gitDir),
        refs = RefStore(gitDir, _commonDir(gitDir)) {
    final cfg = config;
    final version =
        int.tryParse(cfg.get('core', null, 'repositoryformatversion') ?? '0') ??
            0;
    final name = cfg.get('extensions', null, 'objectformat');
    if (version > 1) {
      throw GitError('unsupported repository format version $version');
    }
    try {
      format = ObjectFormat.parse(version == 0 ? null : name);
    } on FormatException {
      throw GitError("invalid value for 'extensions.objectformat': '$name'");
    }
    odb = ObjectDatabase(joinPath(commonDir, 'objects'), format);
  }

  /// The `commondir` a linked worktree's git directory points at.
  static String _commonDir(String gitDir) {
    final f = File(joinPath(gitDir, 'commondir'));
    if (!f.existsSync()) return gitDir;
    final c = f.readAsStringSync().trim();
    return File(c).isAbsolute ? c : joinPath(gitDir, c);
  }

  /// Path of [name] inside the git directory (see [gitPath]).
  String path(String name) => gitPath(gitDir, commonDir, name);

  /// The object format (`extensions.objectFormat`): SHA-1 or SHA-256.
  late final ObjectFormat format;

  /// The `.git` directory (or the bare repository itself); for a linked
  /// worktree, its own directory under `<common>/worktrees/`.
  final String gitDir;

  /// The directory holding objects, refs and config: [gitDir] except in a
  /// linked worktree.
  final String commonDir;

  /// The working tree, or null for a bare repository.
  final String? workDir;
  late final ObjectDatabase odb;
  final RefStore refs;
  GitConfig? _config;

  GitConfig get config =>
      _config ??= GitConfig.load(joinPath(commonDir, 'config'));

  bool get isBare => workDir == null;

  String get _work {
    final w = workDir;
    if (w == null) throw GitError('operation needs a working tree');
    return w;
  }

  static bool _looksLikeGitDir(String dir) {
    final common = _commonDir(dir);
    return File(joinPath(dir, 'HEAD')).existsSync() &&
        Directory(joinPath(common, 'objects')).existsSync() &&
        Directory(joinPath(common, 'refs')).existsSync();
  }

  /// Opens the repository whose work tree is [dir] (or the bare repository
  /// at [dir]); returns null when [dir] is not a repository.
  static Repository? tryOpen(String dir) {
    final abs = Directory(dir).absolute.path;
    final dotGit = joinPath(abs, '.git');
    if (FileSystemEntity.isDirectorySync(dotGit) && _looksLikeGitDir(dotGit)) {
      return Repository._(dotGit, abs);
    }
    if (FileSystemEntity.isFileSync(dotGit)) {
      // `gitdir: <path>` indirection (worktrees, separate git dirs).
      final line = File(dotGit).readAsStringSync().trim();
      if (line.startsWith('gitdir:')) {
        var target = line.substring(7).trim();
        if (!File(target).isAbsolute) target = joinPath(abs, target);
        if (_looksLikeGitDir(target)) return Repository._(target, abs);
      }
      return null;
    }
    if (_looksLikeGitDir(abs)) {
      final cfg = GitConfig.load(joinPath(abs, 'config'));
      if (cfg.get('core', null, 'bare') != 'false') {
        return Repository._(abs, null);
      }
    }
    return null;
  }

  static Repository open(String dir) {
    final r = tryOpen(dir);
    if (r == null) throw GitError('$dir is not a Git repository');
    return r;
  }

  /// `git init [--bare] [-b <branch>]`: creates a repository in [dir] with
  /// HEAD pointing at the unborn [branch]. Re-initialising an existing
  /// repository leaves it unchanged.
  static Repository init(String dir,
      {String branch = 'master',
      bool bare = false,
      ObjectFormat format = ObjectFormat.sha1}) {
    final existing = tryOpen(dir);
    if (existing != null) return existing;
    final abs = Directory(dir).absolute.path;
    final gitDir = bare ? abs : joinPath(abs, '.git');
    for (final d in [
      'objects/info',
      'objects/pack',
      'refs/heads',
      'refs/tags',
      'info'
    ]) {
      Directory(joinPath(gitDir, d)).createSync(recursive: true);
    }
    File(joinPath(gitDir, 'HEAD'))
        .writeAsStringSync('ref: refs/heads/$branch\n');
    final cfg = GitConfig.load(joinPath(gitDir, 'config'));
    // Like git: version 1 plus the extension only for non-default formats.
    cfg.set('core', null, 'repositoryformatversion',
        format == ObjectFormat.sha1 ? '0' : '1');
    cfg.set('core', null, 'filemode', Platform.isWindows ? 'false' : 'true');
    cfg.set('core', null, 'bare', bare ? 'true' : 'false');
    if (!bare) cfg.set('core', null, 'logallrefupdates', 'true');
    if (format != ObjectFormat.sha1) {
      cfg.set('extensions', null, 'objectformat', format.name);
    }
    cfg.save();
    return Repository._(gitDir, bare ? null : abs);
  }

  void close() => odb.close();

  GitIndex readIndex() => GitIndex.read(gitDir, format);

  void writeIndex(GitIndex index) => index.write(gitDir, format);

  // -------------------------------------------------------------------------
  // HEAD

  /// The branch HEAD points at (e.g. `refs/heads/main`), null if detached.
  String? get headRef => refs.symbolicTarget('HEAD');

  /// Commit id of HEAD, null if the branch is unborn.
  String? get headCommit => refs.resolve('HEAD');

  /// Identity recorded in reflog entries.
  Signature? identity;

  bool get _logRefUpdates {
    final v = config.get('core', null, 'logallrefupdates');
    return v == null ? !isBare : v == 'true' || v == 'always';
  }

  /// Updates (or with [id] null deletes) ref [name] and appends to its
  /// reflog (and HEAD's when HEAD points at it), like `git update-ref -m`.
  void updateRef(String name, String? id, String message) {
    final old = refs.resolve(name) ?? format.zeroId;
    if (id == null) {
      refs.delete(name);
      final log = File(path('logs/$name'));
      if (log.existsSync()) log.deleteSync();
      return;
    }
    refs.update(name, id);
    final who = identity;
    if (!_logRefUpdates || who == null) return;
    final line = '$old $id ${who.format()}\t$message\n';
    final targets = [
      if (name.startsWith('refs/heads/') ||
          name.startsWith('refs/remotes/') ||
          name == 'HEAD')
        name,
      if (name != 'HEAD' && headRef == name) 'HEAD',
    ];
    for (final t in targets) {
      final f = File(path('logs/$t'));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(line, mode: FileMode.append);
    }
  }

  Map<String, TreeEntry> treeOfCommit(String? commit) =>
      commit == null ? {} : odb.flattenTree(odb.readCommit(commit).tree);

  // -------------------------------------------------------------------------
  // Working tree

  IgnoreRules _loadIgnore() {
    final rules = IgnoreRules();
    final exclude = File(path('info/exclude'));
    if (exclude.existsSync()) rules.addPatterns('', exclude.readAsStringSync());
    return rules;
  }

  /// Lists files of the working tree, skipping `.git`, ignored paths
  /// (unless tracked in [index] or [head]) and nested repositories other
  /// than tracked submodules.
  Map<String, WorkFile> scanWorktree(
      GitIndex index, Map<String, TreeEntry> head) {
    final tracked = {...index.entries.keys, ...head.keys};
    bool isGitlink(String p) =>
        (index.entries[p]?.modeString ?? head[p]?.mode) == modeGitlink;
    final root = _work;
    final rules = _loadIgnore();
    final out = <String, WorkFile>{};
    final trackedDirs = <String>{};
    for (final t in tracked) {
      var i = t.lastIndexOf('/');
      while (i > 0) {
        if (!trackedDirs.add(t.substring(0, i))) break;
        i = t.lastIndexOf('/', i - 1);
      }
    }
    void walk(String rel) {
      final dirPath = rel.isEmpty ? root : joinPath(root, rel);
      final gi = File(joinPath(dirPath, '.gitignore'));
      if (gi.existsSync()) {
        try {
          rules.addPatterns(rel, gi.readAsStringSync());
        } on FileSystemException {
          // Unreadable .gitignore: ignore it.
        }
      }
      final List<FileSystemEntity> children;
      try {
        children = Directory(dirPath).listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final e in children) {
        final sep = e.path.lastIndexOf(Platform.pathSeparator);
        final decoded = e.path.substring(sep + 1);
        if (decoded == '.git') continue;
        final path = rel.isEmpty ? decoded : '$rel/$decoded';
        if (e is Directory && isGitlink(path)) {
          // A gitlink (submodule): the directory stands for one commit.
          out[path] = WorkFile(path, modeGitlink, e.statSync());
        } else if (e is Directory) {
          if (!trackedDirs.contains(path)) {
            if (rules.isIgnored(path, isDir: true)) continue;
            if (FileSystemEntity.typeSync(joinPath(e.path, '.git'),
                    followLinks: false) !=
                FileSystemEntityType.notFound) {
              continue; // nested repository
            }
          }
          walk(path);
        } else if (e is File || e is Link) {
          if (!tracked.contains(path) && rules.isIgnored(path, isDir: false)) {
            continue;
          }
          final stat = e is Link ? FileStat.statSync(e.path) : e.statSync();
          String mode;
          if (e is Link && !Platform.isWindows) {
            mode = modeLink;
          } else if (!Platform.isWindows && (stat.mode & 0x40) != 0) {
            mode = modeExec;
          } else {
            mode = modeFile;
          }
          out[path] = WorkFile(path, mode, stat);
        }
      }
    }

    walk('');
    return out;
  }

  /// Content of the working-tree file at [path] as Git would store it.
  Uint8List? readWorkFile(String path) {
    final full = joinPath(_work, path);
    final type = FileSystemEntity.typeSync(full, followLinks: false);
    if (type == FileSystemEntityType.notFound ||
        type == FileSystemEntityType.directory) {
      return null;
    }
    if (type == FileSystemEntityType.link && !Platform.isWindows) {
      return utf8Bytes(
          Link(full).targetSync().replaceAll(Platform.pathSeparator, '/'));
    }
    return File(full).readAsBytesSync();
  }

  /// Mode for a working-tree file, honouring the known mode on Windows.
  String modeFor(WorkFile f, String? knownMode) {
    if (f.mode == modeGitlink) return modeGitlink;
    if (Platform.isWindows) {
      return knownMode == modeExec || knownMode == modeLink
          ? knownMode!
          : modeFile;
    }
    if (config.get('core', null, 'filemode') == 'false' && f.mode != modeLink) {
      return knownMode == modeExec ? modeExec : modeFile;
    }
    return f.mode;
  }

  /// Computes the blob id of a working file, using the index stat cache
  /// when it is trustworthy; writes the blob when [write] is set.
  String blobIdFor(WorkFile f, GitIndex index, {required bool write}) {
    final cached = index.entries[f.path];
    if (f.mode == modeGitlink) {
      // Like git: the submodule's HEAD, or the recorded commit when the
      // submodule is not checked out.
      final sub = tryOpen(joinPath(_work, f.path));
      final id = sub?.headCommit;
      sub?.close();
      return id ?? cached?.id ?? format.zeroId;
    }
    // Dart has no lstat: a symlink's stat is its target's, so links are
    // always re-hashed (the blob is just the target path).
    if (cached != null && f.mode != modeLink && cached.statMatches(f.stat)) {
      final racy = index.fileMtime == null ||
          !f.stat.modified.isBefore(index.fileMtime!);
      if (!racy && (!write || odb.has(cached.id))) return cached.id;
    }
    final data = readWorkFile(f.path) ?? Uint8List(0);
    return write
        ? odb.write(ObjectType.blob, data)
        : hashObject(ObjectType.blob, data, format);
  }

  /// Flat tree describing the working tree: tracked files plus untracked,
  /// non-ignored files.
  Map<String, TreeEntry> worktreeTree(
    GitIndex index,
    Map<String, TreeEntry> head, {
    required bool write,
    bool includeUntracked = true,
  }) {
    final tracked = {...index.entries.keys, ...head.keys};
    final files = scanWorktree(index, head);
    final out = <String, TreeEntry>{};
    for (final f in files.values) {
      final isTracked = tracked.contains(f.path);
      if (!isTracked) {
        if (!includeUntracked) continue;
      }
      final known = index.entries[f.path]?.modeString ?? head[f.path]?.mode;
      final mode = modeFor(f, known);
      out[f.path] = TreeEntry(mode, f.path, blobIdFor(f, index, write: write));
    }
    return out;
  }

  IndexEntry indexEntryFor(String path, String id, String mode) {
    final full = joinPath(_work, path);
    if (mode == modeGitlink) {
      return IndexEntry(path: path, id: id, mode: int.parse(mode, radix: 8));
    }
    if (mode == modeLink) {
      // No lstat in Dart: record git's size for a link (its target's
      // length) and no times, so git re-checks it instead of trusting us.
      final target = readWorkFile(path);
      return IndexEntry(
          path: path,
          id: id,
          mode: int.parse(mode, radix: 8),
          size: target?.length ?? 0);
    }
    final stat = FileStat.statSync(full);
    if (stat.type == FileSystemEntityType.notFound) {
      return IndexEntry(path: path, id: id, mode: int.parse(mode, radix: 8));
    }
    return IndexEntry.fromStat(path, id, int.parse(mode, radix: 8), stat);
  }

  /// Rewrites the working tree from [from] to [to] (both flat trees) and
  /// replaces the index with [to]. Files not in either tree are untouched.
  void checkout(Map<String, TreeEntry> from, Map<String, TreeEntry> to) {
    final root = _work;
    final old = readIndex();
    for (final p in from.keys) {
      if (to.containsKey(p)) continue;
      final full = joinPath(root, p);
      final t = FileSystemEntity.typeSync(full, followLinks: false);
      if (t == FileSystemEntityType.file || t == FileSystemEntityType.link) {
        _deleteFile(full, t);
        _pruneEmptyDirs(p);
      }
    }
    for (final e in to.entries) {
      final prev = from[e.key];
      final full = joinPath(root, e.key);
      final exists = FileSystemEntity.typeSync(full, followLinks: false) !=
          FileSystemEntityType.notFound;
      if (prev != null &&
          prev.id == e.value.id &&
          prev.mode == e.value.mode &&
          exists) {
        continue;
      }
      _writeWorkFile(e.key, e.value);
    }
    final index = GitIndex({});
    for (final e in to.entries) {
      final prev = from[e.key];
      final oldEntry = old.entries[e.key];
      final unchanged =
          prev != null && prev.id == e.value.id && prev.mode == e.value.mode;
      if (unchanged && oldEntry != null && oldEntry.id == e.value.id) {
        index.entries[e.key] = oldEntry;
      } else if (unchanged) {
        // Unknown stat data: force a content check next time.
        index.entries[e.key] = IndexEntry(
            path: e.key,
            id: e.value.id,
            mode: int.parse(e.value.mode, radix: 8));
      } else {
        index.entries[e.key] = indexEntryFor(e.key, e.value.id, e.value.mode);
      }
    }
    writeIndex(index);
  }

  /// Deletes a file or symlink (a link itself, never its target).
  static void _deleteFile(String full, FileSystemEntityType type) =>
      type == FileSystemEntityType.link
          ? Link(full).deleteSync()
          : File(full).deleteSync();

  void _writeWorkFile(String path, TreeEntry e) {
    final full = joinPath(_work, path);
    final t = FileSystemEntity.typeSync(full, followLinks: false);
    if (t == FileSystemEntityType.directory) {
      Directory(full).deleteSync(recursive: true);
    } else if (t != FileSystemEntityType.notFound) {
      _deleteFile(full, t);
    }
    // A file may be in the way of a directory we need.
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      final dir = joinPath(_work, parts.sublist(0, i).join('/'));
      final t = FileSystemEntity.typeSync(dir, followLinks: false);
      if (t == FileSystemEntityType.file || t == FileSystemEntityType.link) {
        _deleteFile(dir, t);
      }
    }
    File(full).parent.createSync(recursive: true);
    if (e.mode == modeGitlink) {
      Directory(full).createSync(recursive: true);
      return;
    }
    final data = odb.read(e.id).data;
    if (e.mode == modeLink && !Platform.isWindows) {
      Link(full).createSync(String.fromCharCodes(data));
      return;
    }
    File(full).writeAsBytesSync(data);
    if (e.mode == modeExec && !Platform.isWindows) {
      try {
        Process.runSync('chmod', ['+x', full]);
      } on ProcessException {
        // No chmod available (mobile): keep the file non-executable.
      }
    }
  }

  void _pruneEmptyDirs(String path) {
    var i = path.lastIndexOf('/');
    while (i > 0) {
      final dir = Directory(joinPath(_work, path.substring(0, i)));
      try {
        if (dir.listSync().isNotEmpty) return;
        dir.deleteSync();
      } on FileSystemException {
        return;
      }
      i = path.lastIndexOf('/', i - 1);
    }
  }
}
