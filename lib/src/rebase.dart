/// `git rebase <upstream>`, replayed in memory.
library;

import 'history.dart';
import 'merge.dart';
import 'objects.dart';
import 'repository.dart';
import 'util.dart';
import 'worktree.dart';

/// Outcome of [rebase].
class RebaseResult {
  RebaseResult({required this.head, this.conflicts = const []});

  /// The branch tip after the rebase (unchanged when it conflicted).
  final String? head;

  /// Files that conflicted; empty on success.
  final List<String> conflicts;

  bool get ok => conflicts.isEmpty;

  @override
  String toString() => ok ? 'RebaseResult($head)' : 'RebaseResult($conflicts)';
}

/// `git rebase <upstream>` for the current branch: its first-parent commits
/// that are not in [upstream] are replayed on top of it (line-based 3-way
/// merge per file); commits that become empty are dropped, and when the
/// branch is already contained in [upstream] it fast-forwards.
///
/// The replay happens in memory. When a step conflicts the result is what
/// `git rebase` followed by `git rebase --abort` leaves: branch, index and
/// working tree unchanged, and the conflicting files are reported.
RebaseResult rebase(Repository repo, String upstream,
    {required Signature committer}) {
  final onto = revParse(repo, upstream);
  if (onto == null) throw GitError("invalid upstream '$upstream'");
  final local = repo.headCommit;
  if (local == null) throw GitError('cannot rebase an unborn branch');
  if (status(repo).any((e) => e.index != '?')) {
    throw GitError('cannot rebase: you have unstaged or staged changes');
  }
  final odb = repo.odb;
  var tip = onto;
  var current = repo.treeOfCommit(onto);
  for (final id in commitsToReplay(odb, local, onto)) {
    final c = odb.readCommit(id);
    final base = c.parents.isEmpty
        ? <String, TreeEntry>{}
        : repo.treeOfCommit(c.parents.first);
    final m = mergeTrees(odb, base, current, odb.flattenTree(c.tree));
    if (m.conflicts.isNotEmpty) {
      return RebaseResult(head: local, conflicts: m.conflicts);
    }
    if (_sameTree(m.tree, current)) continue; // already upstream
    tip = odb.write(
        ObjectType.commit,
        Commit(
          tree: odb.writeTreeFromFlat(m.tree),
          parents: [tip],
          author: c.author,
          committer: committer,
          message: c.message,
        ).serialize());
    current = m.tree;
  }
  if (tip != local) {
    resetHard(repo, tip,
        reflogMessage: 'rebase (finish): ${repo.headRef ?? 'HEAD'} onto $onto');
  }
  return RebaseResult(head: tip);
}

bool _sameTree(Map<String, TreeEntry> a, Map<String, TreeEntry> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null || o.id != e.value.id || o.mode != e.value.mode) return false;
  }
  return true;
}
