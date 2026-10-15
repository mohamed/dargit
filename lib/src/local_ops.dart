import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'index.dart';
import 'objects.dart';
import 'repository.dart';
import 'util.dart';

/// One entry of a file's history.
class Revision {
  Revision({
    required this.commit,
    required this.path,
    required this.author,
    required this.date,
    required this.message,
  });

  /// Full commit id.
  final String commit;

  /// Path of the file in that commit (differs from the requested path
  /// before a rename).
  final String path;

  /// Author name.
  final String author;

  /// Author date.
  final DateTime date;

  /// Full commit message (without the trailing newline).
  final String message;

  @override
  String toString() => 'Revision($commit, $path, $author, $date)';
}

String normalizePath(String p) {
  var s = p.replaceAll('\\', '/');
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

bool _sameTree(Map<String, TreeEntry> a, Map<String, TreeEntry> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null || o.id != e.value.id || o.mode != e.value.mode) return false;
  }
  return true;
}

bool _under(String path, String prefix) =>
    prefix.isEmpty || path == prefix || path.startsWith('$prefix/');

/// Commits working-tree changes. See [GitBackend.commit].
bool commitChanges(
  Repository repo,
  String message, {
  List<String>? paths,
  required Signature author,
}) {
  final head = repo.headCommit;
  final headTree = repo.treeOfCommit(head);
  final index = GitIndex.read(repo.gitDir);
  final Map<String, TreeEntry> newTree;
  final GitIndex newIndex;

  if (paths == null) {
    newTree = repo.worktreeTree(index, headTree, write: true);
    newIndex = GitIndex({});
    for (final e in newTree.entries) {
      final old = index.entries[e.key];
      newIndex.entries[e.key] = old != null &&
              old.id == e.value.id &&
              old.modeString == e.value.mode &&
              old.mtimeSec != 0
          ? old
          : repo.indexEntryFor(e.key, e.value.id, e.value.mode);
    }
  } else {
    newTree = {...headTree};
    newIndex = GitIndex({...index.entries});
    newIndex.conflicts.addAll(index.conflicts);
    final norm = paths.map(normalizePath).toSet();
    Map<String, WorkFile>? scanned;
    for (final p in norm) {
      newTree.removeWhere((k, _) => _under(k, p));
      newIndex.entries.removeWhere((k, _) => _under(k, p));
      newIndex.conflicts.removeWhere((e) => _under(e.path, p));
      final full = joinPath(repo.workDir!, p);
      final type = FileSystemEntity.typeSync(full, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      scanned ??= repo.scanWorktree({...index.entries.keys, ...headTree.keys});
      for (final f in scanned.values) {
        if (!_under(f.path, p)) continue;
        // An explicitly named file is committed even if ignored; files
        // found inside a named directory follow the normal rules.
        final known =
            index.entries[f.path]?.modeString ?? headTree[f.path]?.mode;
        final mode = repo.modeFor(f, known);
        final id = repo.blobIdFor(f, index, write: true);
        newTree[f.path] = TreeEntry(mode, f.path, id);
        newIndex.entries[f.path] = repo.indexEntryFor(f.path, id, mode);
      }
      if (type != FileSystemEntityType.directory && !newTree.containsKey(p)) {
        // Ignored file named explicitly.
        final data = repo.readWorkFile(p);
        if (data != null) {
          final id = repo.odb.write(ObjectType.blob, data);
          final stat = FileStat.statSync(full);
          final mode = !Platform.isWindows && (stat.mode & 0x40) != 0
              ? modeExec
              : modeFile;
          newTree[p] = TreeEntry(mode, p, id);
          newIndex.entries[p] = repo.indexEntryFor(p, id, mode);
        }
      }
    }
  }

  final unchanged = _sameTree(newTree, headTree);
  if (unchanged) {
    if (paths == null || head != null) newIndex.write(repo.gitDir);
    return false;
  }
  final treeId = repo.odb.writeTreeFromFlat(newTree);
  var msg = message;
  if (!msg.endsWith('\n')) msg = '$msg\n';
  final commit = Commit(
    tree: treeId,
    parents: [if (head != null) head],
    author: author,
    committer: author,
    message: msg,
  );
  final id = repo.odb.write(ObjectType.commit, commit.serialize());
  repo.refs.update(repo.headRef ?? 'HEAD', id);
  newIndex.write(repo.gitDir);
  return true;
}

/// Whether working tree and index match HEAD (untracked files under
/// [appStateDir] and ignored files do not count).
bool isClean(Repository repo) {
  final headTree = repo.treeOfCommit(repo.headCommit);
  final index = GitIndex.read(repo.gitDir);
  if (index.conflicts.isNotEmpty) return false;
  if (index.entries.length != headTree.length) return false;
  for (final e in index.entries.values) {
    final h = headTree[e.path];
    if (h == null || h.id != e.id || h.mode != e.modeString) return false;
  }
  final work = repo.worktreeTree(index, headTree, write: false);
  return _sameTree(work, headTree);
}

/// Paths that differ between the working tree and HEAD.
List<String> changedPaths(Repository repo) {
  final headTree = repo.treeOfCommit(repo.headCommit);
  final index = GitIndex.read(repo.gitDir);
  final work = repo.worktreeTree(index, headTree, write: false);
  final out = <String>{};
  for (final e in work.entries) {
    final h = headTree[e.key];
    if (h == null || h.id != e.value.id || h.mode != e.value.mode) {
      out.add(e.key);
    }
  }
  for (final k in headTree.keys) {
    if (!work.containsKey(k)) out.add(k);
  }
  return out.toList()..sort();
}

// ---------------------------------------------------------------------------
// Commit graph

/// All commits reachable from [tips].
Set<String> reachable(ObjectDatabase odb, Iterable<String?> tips,
    {Set<String>? stopAt}) {
  final seen = <String>{};
  final queue = Queue<String>()..addAll(tips.whereType<String>());
  while (queue.isNotEmpty) {
    final c = queue.removeFirst();
    if (stopAt != null && stopAt.contains(c)) continue;
    if (!seen.add(c)) continue;
    final o = odb.tryRead(c);
    if (o == null) continue; // shallow/missing history
    queue.addAll(Commit.parse(o.data).parents);
  }
  return seen;
}

/// Commits in [local] not in [remote] (ahead) and the reverse (behind).
({int ahead, int behind}) aheadBehind(
    ObjectDatabase odb, String? local, String? remote) {
  if (local == remote) return (ahead: 0, behind: 0);
  final a = reachable(odb, [local]);
  final b = reachable(odb, [remote]);
  return (ahead: a.difference(b).length, behind: b.difference(a).length);
}

bool isAncestor(ObjectDatabase odb, String ancestor, String descendant) =>
    reachable(odb, [descendant]).contains(ancestor);

/// Commits of [tip] not reachable from [base], oldest first, following
/// first parents (the commits a rebase replays).
List<String> commitsToReplay(ObjectDatabase odb, String tip, String base) {
  final exclude = reachable(odb, [base]);
  final out = <String>[];
  String? c = tip;
  while (c != null && !exclude.contains(c)) {
    out.add(c);
    final parents = odb.readCommit(c).parents;
    c = parents.isEmpty ? null : parents.first;
  }
  return out.reversed.toList();
}

// ---------------------------------------------------------------------------
// History

/// Resolves a commit-ish: full id, unique abbreviated id, or ref name.
String? resolveCommitish(Repository repo, String rev) {
  final r = rev.trim();
  if (isObjectId(r)) return repo.odb.has(r) ? r : null;
  for (final name in [r, 'refs/heads/$r', 'refs/remotes/$r', 'refs/tags/$r']) {
    if (name.isEmpty) continue;
    final id = repo.refs.resolve(name);
    if (id != null) return id;
  }
  if (RegExp(r'^[0-9a-f]{4,39}$').hasMatch(r)) return repo.odb.resolvePrefix(r);
  return null;
}

double _similarity(List<int> a, List<int> b) {
  if (a.isEmpty && b.isEmpty) return 1;
  List<String> lines(List<int> d) =>
      utf8.decode(d, allowMalformed: true).split('\n');
  final counts = <String, int>{};
  final la = lines(a), lb = lines(b);
  for (final l in la) {
    counts[l] = (counts[l] ?? 0) + 1;
  }
  var common = 0;
  for (final l in lb) {
    final n = counts[l] ?? 0;
    if (n > 0) {
      common++;
      counts[l] = n - 1;
    }
  }
  final total = la.length > lb.length ? la.length : lb.length;
  return common / total;
}

/// Newest-first history of [path], following renames along first parents.
List<Revision> fileHistory(Repository repo, String path, {String? from}) {
  var current = normalizePath(path);
  final odb = repo.odb;
  final out = <Revision>[];
  var c = from ?? repo.headCommit;
  while (c != null) {
    final commit = odb.readCommit(c);
    final parent = commit.parents.isEmpty ? null : commit.parents.first;
    final mine = odb.lookupPath(commit.tree, current);
    final parentTree = parent == null ? null : odb.readCommit(parent).tree;
    final theirs =
        parentTree == null ? null : odb.lookupPath(parentTree, current);
    final mineId = mine == null || mine.isTree ? null : mine.id;
    final theirsId = theirs == null || theirs.isTree ? null : theirs.id;
    var stop = false;
    if (mineId != theirsId) {
      out.add(Revision(
        commit: c,
        path: current,
        author: commit.author.name,
        date: commit.author.time,
        message: commit.message.endsWith('\n')
            ? commit.message.substring(0, commit.message.length - 1)
            : commit.message,
      ));
      if (mineId != null && theirsId == null) {
        if (parentTree == null) {
          stop = true;
        } else {
          final renamed =
              _findRenameSource(repo, commit.tree, parentTree, mineId);
          if (renamed == null) {
            stop = true;
          } else {
            current = renamed;
          }
        }
      }
    }
    if (stop) break;
    c = parent;
  }
  return out;
}

String? _findRenameSource(
    Repository repo, String tree, String parentTree, String blob) {
  final now = repo.odb.flattenTree(tree);
  final before = repo.odb.flattenTree(parentTree);
  final deleted = before.entries.where((e) => !now.containsKey(e.key)).toList();
  for (final e in deleted) {
    if (e.value.id == blob) return e.key;
  }
  // Inexact rename: best line similarity of at least 50%.
  final target = repo.odb.read(blob).data;
  String? best;
  var bestScore = 0.5;
  for (final e in deleted) {
    if (e.value.mode == modeGitlink) continue;
    final s = _similarity(repo.odb.read(e.value.id).data, target);
    if (s >= bestScore) {
      bestScore = s;
      best = e.key;
    }
  }
  return best;
}
