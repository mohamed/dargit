/// Commands that read or change the index and working tree: `status`,
/// `add`, `commit` and `reset --hard`.
library;

import 'index.dart';
import 'objects.dart';
import 'repository.dart';
import 'util.dart';

/// One line of `git status --porcelain --untracked-files=all`.
class StatusEntry {
  StatusEntry(this.path, this.index, this.worktree);

  final String path;

  /// Status in the index relative to HEAD: `M`, `A`, `D`, `U` (unmerged),
  /// `?` (untracked) or ` `.
  final String index;

  /// Status in the working tree relative to the index: `M`, `D`, `?` or ` `.
  final String worktree;

  /// The porcelain line; like git, paths with whitespace, quotes,
  /// backslashes or control characters are C-quoted (non-ASCII is kept, as
  /// with `core.quotePath=false`).
  @override
  String toString() => '$index$worktree ${_quote(path)}';

  static String _quote(String p) {
    if (!RegExp(r'[\s"\\\x00-\x1f\x7f]').hasMatch(p)) return p;
    final sb = StringBuffer('"');
    for (final c in p.codeUnits) {
      sb.write(switch (c) {
        0x22 => r'\"',
        0x5c => r'\\',
        0x09 => r'\t',
        0x0a => r'\n',
        _ when c < 0x20 || c == 0x7f =>
          '\\${c.toRadixString(8).padLeft(3, '0')}',
        _ => String.fromCharCode(c),
      });
    }
    return (sb..write('"')).toString();
  }

  @override
  bool operator ==(Object other) =>
      other is StatusEntry &&
      other.path == path &&
      other.index == index &&
      other.worktree == worktree;

  @override
  int get hashCode => Object.hash(path, index, worktree);
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
  return s == '.' ? '' : s;
}

bool _same(TreeEntry? a, TreeEntry? b) =>
    a == null ? b == null : b != null && a.id == b.id && a.mode == b.mode;

bool _sameTree(Map<String, TreeEntry> a, Map<String, TreeEntry> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (!_same(e.value, b[e.key])) return false;
  }
  return true;
}

/// Whether [path] is [spec] or inside directory [spec] ('' matches all).
bool underPathspec(String path, String spec) =>
    spec.isEmpty || path == spec || path.startsWith('$spec/');

Map<String, TreeEntry> _indexTree(GitIndex index) => {
      for (final e in index.entries.values)
        e.path: TreeEntry(e.modeString, e.path, e.id),
    };

/// `git status --porcelain --untracked-files=all` (ignored files are not
/// listed; renames are reported as a deletion plus an addition).
List<StatusEntry> status(Repository repo) {
  final head = repo.treeOfCommit(repo.headCommit);
  final index = repo.readIndex();
  final staged = _indexTree(index);
  final work = repo.worktreeTree(index, head, write: false);
  final unmerged = {for (final c in index.conflicts) c.path};
  final paths = {...head.keys, ...staged.keys, ...work.keys, ...unmerged};
  final out = <StatusEntry>[];
  for (final p in paths) {
    if (unmerged.contains(p)) {
      out.add(StatusEntry(p, 'U', 'U'));
      continue;
    }
    final h = head[p], i = staged[p], w = work[p];
    if (i == null && h == null) {
      if (w != null) out.add(StatusEntry(p, '?', '?'));
      continue;
    }
    final x = i == null
        ? 'D'
        : h == null
            ? 'A'
            : _same(h, i)
                ? ' '
                : 'M';
    final y = i == null
        ? ' '
        : w == null
            ? 'D'
            : _same(i, w)
                ? ' '
                : 'M';
    // A file deleted from the index but present on disk is also untracked.
    if (i == null && w != null) {
      out.add(StatusEntry(p, 'D', ' '));
      out.add(StatusEntry(p, '?', '?'));
      continue;
    }
    if (x != ' ' || y != ' ') out.add(StatusEntry(p, x, y));
  }
  // Like git: tracked changes first, then untracked files, each by path.
  out.sort((a, b) {
    final ua = a.index == '?', ub = b.index == '?';
    if (ua != ub) return ua ? 1 : -1;
    return comparePaths(a.path, b.path);
  });
  return out;
}

/// `git add -A -- <pathspecs>`: stages additions, modifications and
/// deletions below each pathspec ('.' for everything). Ignored untracked
/// files are skipped.
void add(Repository repo, List<String> pathspecs) {
  final head = repo.treeOfCommit(repo.headCommit);
  final index = repo.readIndex();
  _stage(repo, index, head, pathspecs.map(normalizePath).toSet());
  repo.writeIndex(index);
}

/// Updates [index] below [specs] from the working tree, writing blobs.
void _stage(Repository repo, GitIndex index, Map<String, TreeEntry> head,
    Set<String> specs) {
  bool matches(String p) => specs.any((s) => underPathspec(p, s));
  final files = repo.scanWorktree(index, head);
  index.entries.removeWhere((p, _) => matches(p) && !files.containsKey(p));
  index.conflicts.removeWhere((e) => matches(e.path));
  for (final f in files.values) {
    if (!matches(f.path)) continue;
    final old = index.entries[f.path];
    final mode = repo.modeFor(f, old?.modeString ?? head[f.path]?.mode);
    final id = repo.blobIdFor(f, index, write: true);
    if (old != null &&
        old.id == id &&
        old.modeString == mode &&
        old.statMatches(f.stat)) {
      continue;
    }
    index.entries[f.path] = repo.indexEntryFor(f.path, id, mode);
  }
}

/// `git commit -m <message>` (commits the index), or with [only]
/// `git add -A -- <only> && git commit --only -m <message> -- <only>`: the
/// new tree is HEAD's with just those paths taken from the working tree
/// (a missing file is a deletion), so changes staged elsewhere are neither
/// committed nor unstaged. A pathspec matching nothing is ignored.
///
/// Returns the new commit id, or null when there is nothing to commit.
String? commit(Repository repo, String message,
    {List<String>? only, required Signature author}) {
  final head = repo.headCommit;
  final headTree = repo.treeOfCommit(head);
  final index = repo.readIndex();
  final Map<String, TreeEntry> tree;
  if (only == null) {
    if (index.conflicts.isNotEmpty) {
      throw GitError('committing is not possible because you have '
          'unmerged files');
    }
    tree = _indexTree(index);
  } else {
    final specs = only.map(normalizePath).toSet();
    _stage(repo, index, headTree, specs);
    tree = {
      for (final e in headTree.entries)
        if (!specs.any((s) => underPathspec(e.key, s))) e.key: e.value,
      for (final e in index.entries.values)
        if (specs.any((s) => underPathspec(e.path, s)))
          e.path: TreeEntry(e.modeString, e.path, e.id),
    };
    repo.writeIndex(index);
  }
  if (_sameTree(tree, headTree)) return null;
  var msg = message;
  if (!msg.endsWith('\n')) msg = '$msg\n';
  final c = Commit(
    tree: repo.odb.writeTreeFromFlat(tree),
    parents: [if (head != null) head],
    author: author,
    committer: author,
    message: msg,
  );
  final id = repo.odb.write(ObjectType.commit, c.serialize());
  final subject = msg.split('\n').first;
  repo.updateRef(repo.headRef ?? 'HEAD', id,
      head == null ? 'commit (initial): $subject' : 'commit: $subject');
  return id;
}

/// `git reset --hard <commit>`: moves the current branch (or detached HEAD)
/// to [target] and makes index and working tree match it, discarding
/// changes to tracked files. Untracked files are left alone.
void resetHard(Repository repo, String target,
    {required String reflogMessage}) {
  final head = repo.treeOfCommit(repo.headCommit);
  final index = repo.readIndex();
  // What is on disk now for every tracked path.
  final current =
      repo.worktreeTree(index, head, write: false, includeUntracked: false);
  final tracked = {...head.keys, ...index.entries.keys};
  final from = <String, TreeEntry>{
    for (final p in tracked)
      if (current[p] != null) p: current[p]!,
  };
  repo.checkout(from, repo.treeOfCommit(target));
  repo.updateRef(repo.headRef ?? 'HEAD', target, reflogMessage);
}
