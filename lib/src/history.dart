/// Read-only history commands: `rev-parse`, `rev-list`, `log`, `show`.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'objects.dart';
import 'repository.dart';
import 'util.dart';
import 'worktree.dart' show normalizePath;

/// One commit of `git log` output.
class LogEntry {
  LogEntry({
    required this.commit,
    required this.path,
    required this.authorName,
    required this.authorEmail,
    required this.date,
    required this.message,
  });

  /// Full commit id.
  final String commit;

  /// The file's path in this commit for a path-limited log (it differs
  /// from the requested path before a followed rename), else null.
  final String? path;

  final String authorName;
  final String authorEmail;

  /// Author date.
  final DateTime date;

  /// Full commit message, without the trailing newline.
  final String message;

  /// First line of [message] (`%s`).
  String get subject => message.split('\n').first;

  @override
  String toString() => 'LogEntry($commit, $path, $subject)';
}

/// All commits reachable from [tips].
Set<String> reachable(ObjectDatabase odb, Iterable<String?> tips) {
  final seen = <String>{};
  final queue = Queue<String>()..addAll(tips.whereType<String>());
  while (queue.isNotEmpty) {
    final c = queue.removeFirst();
    if (!seen.add(c)) continue;
    final o = odb.tryRead(c);
    if (o == null) continue; // missing history
    queue.addAll(Commit.parse(o.data).parents);
  }
  return seen;
}

bool isAncestor(ObjectDatabase odb, String ancestor, String descendant) =>
    reachable(odb, [descendant]).contains(ancestor);

/// `git rev-list --count <include> [^<exclude>]`.
int countCommits(ObjectDatabase odb, String include, {String? exclude}) {
  final a = reachable(odb, [include]);
  if (exclude == null) return a.length;
  return a.difference(reachable(odb, [exclude])).length;
}

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

/// `git rev-parse --verify --quiet <rev>^{commit}` for a full or unique
/// abbreviated id, `HEAD`, or a ref name (`main`, `origin/main`,
/// `refs/heads/main`, a tag). Null when it names no commit.
String? revParse(Repository repo, String rev) {
  final r = rev.trim();
  String? id;
  if (repo.format.isId(r)) {
    id = r;
  } else {
    for (final name in [
      r,
      'refs/$r',
      'refs/tags/$r',
      'refs/heads/$r',
      'refs/remotes/$r',
      'refs/remotes/$r/HEAD',
    ]) {
      if (r.isEmpty) break;
      id = repo.refs.resolve(name);
      if (id != null) break;
    }
    if (id == null &&
        RegExp('^[0-9a-f]{4,${repo.format.hexLength - 1}}\$').hasMatch(r)) {
      id = repo.odb.resolvePrefix(r);
    }
  }
  if (id == null) return null;
  // Peel annotated tags.
  for (var i = 0; i < 10; i++) {
    final o = repo.odb.tryRead(id!);
    if (o == null) return null;
    if (o.type == ObjectType.commit) return id;
    if (o.type != ObjectType.tag) return null;
    final m = RegExp(r'^object ([0-9a-f]+)$', multiLine: true)
        .firstMatch(utf8.decode(o.data, allowMalformed: true));
    id = m?.group(1);
    if (id == null) return null;
  }
  return null;
}

String? _blobAt(ObjectDatabase odb, String tree, String path) {
  final e = odb.lookupPath(tree, path);
  return e == null || e.isTree ? null : e.id;
}

/// `git log --first-parent [--follow] [<rev>] [-- <path>]`, newest first.
/// With [path], only commits that changed it are listed (including the one
/// deleting it); with [follow], renames are followed (exact matches, else
/// the most similar deleted file with at least 50% common lines).
List<LogEntry> log(Repository repo,
    {String rev = 'HEAD', String? path, bool follow = false}) {
  final odb = repo.odb;
  var c = revParse(repo, rev);
  if (c == null) {
    if (rev == 'HEAD' && repo.headCommit == null) return []; // unborn
    throw GitError("bad revision '$rev'");
  }
  var current = path == null ? null : normalizePath(path);
  final out = <LogEntry>[];
  String? next = c;
  while (next != null) {
    c = next;
    final commit = odb.readCommit(c);
    final parent = commit.parents.isEmpty ? null : commit.parents.first;
    next = parent;
    LogEntry entry() => LogEntry(
          commit: c!,
          path: current,
          authorName: commit.author.name,
          authorEmail: commit.author.email,
          date: commit.author.time,
          message: commit.message.endsWith('\n')
              ? commit.message.substring(0, commit.message.length - 1)
              : commit.message,
        );
    if (current == null) {
      out.add(entry());
      continue;
    }
    final parentTree = parent == null ? null : odb.readCommit(parent).tree;
    final mine = _blobAt(odb, commit.tree, current);
    final theirs =
        parentTree == null ? null : _blobAt(odb, parentTree, current);
    if (mine == theirs) continue;
    out.add(entry());
    if (follow && mine != null && theirs == null) {
      final from = parentTree == null
          ? null
          : _renameSource(odb, commit.tree, parentTree, mine);
      if (from == null) break; // created here
      current = from;
    }
  }
  return out;
}

/// `git show <rev>:<path>`: the blob's bytes, or null when [rev] or [path]
/// does not exist (or names a directory).
Uint8List? show(Repository repo, String rev, String path) {
  final c = revParse(repo, rev);
  if (c == null) return null;
  final id =
      _blobAt(repo.odb, repo.odb.readCommit(c).tree, normalizePath(path));
  return id == null ? null : repo.odb.read(id).data;
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

String? _renameSource(
    ObjectDatabase odb, String tree, String parentTree, String blob) {
  final now = odb.flattenTree(tree);
  final before = odb.flattenTree(parentTree);
  final deleted = before.entries.where((e) => !now.containsKey(e.key)).toList();
  for (final e in deleted) {
    if (e.value.id == blob) return e.key;
  }
  final target = odb.read(blob).data;
  String? best;
  var bestScore = 0.5;
  for (final e in deleted) {
    if (e.value.mode == modeGitlink) continue;
    final s = _similarity(odb.read(e.value.id).data, target);
    if (s >= bestScore) {
      bestScore = s;
      best = e.key;
    }
  }
  return best;
}
