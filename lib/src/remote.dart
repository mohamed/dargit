import 'dart:io';

import 'local_ops.dart';
import 'merge.dart';
import 'objects.dart';
import 'pack.dart';
import 'packgen.dart';
import 'repository.dart';
import 'transport/transport.dart';
import 'util.dart';

const _tracking = 'refs/remotes/origin/';

/// Commits we can tell the server we have: tips of local and tracking
/// branches plus a few first-parent ancestors.
List<String> _haves(Repository repo) {
  final out = <String>{};
  final tips = {
    ...repo.refs.list('refs/heads/').values,
    ...repo.refs.list(_tracking).values
  };
  for (final tip in tips) {
    String? c = tip;
    for (var i = 0; i < 32 && c != null; i++) {
      final o = repo.odb.tryRead(c);
      if (o == null || o.type != ObjectType.commit) break;
      if (!out.add(c)) break;
      final parents = Commit.parse(o.data).parents;
      c = parents.isEmpty ? null : parents.first;
    }
  }
  return out.toList();
}

/// Fetches all branches of origin into `refs/remotes/origin/*`, pruning
/// tracking refs that no longer exist. Returns the remote branches.
Future<Map<String, String>> fetchOrigin(
    Repository repo, Transport transport) async {
  final session = await transport.openUpload();
  try {
    final heads = <String, String>{};
    session.refs.forEach((k, v) {
      if (k.startsWith('refs/heads/')) heads[k] = v;
    });
    final wants =
        heads.values.where((id) => !repo.odb.has(id)).toSet().toList();
    if (wants.isNotEmpty) {
      final pack = await session.fetchPack(wants, _haves(repo));
      storePack(repo.odb, pack);
      for (final w in wants) {
        if (!repo.odb.has(w)) throw GitError('remote sent an incomplete pack');
      }
    }
    final existing = repo.refs.list(_tracking);
    heads.forEach((name, id) {
      final local = '$_tracking${name.substring('refs/heads/'.length)}';
      if (existing[local] != id) repo.refs.update(local, id);
    });
    for (final name in existing.keys) {
      final remote = 'refs/heads/${name.substring(_tracking.length)}';
      if (!heads.containsKey(remote)) repo.refs.delete(name);
    }
    return heads;
  } finally {
    await session.close();
  }
}

/// Pushes `refs/heads/<branch>`. Without [force] the update must be a
/// fast-forward. With [force], the remote must still be at [lease]
/// (force-with-lease; null = branch must not exist remotely).
Future<void> pushBranch(
  Repository repo,
  Transport transport,
  String branch, {
  bool force = false,
  String? lease,
}) async {
  final ref = 'refs/heads/$branch';
  final local = repo.refs.resolve(ref);
  if (local == null) throw GitError("branch '$branch' has no commits");
  final session = await transport.openReceive();
  try {
    final remote = session.refs[ref];
    if (force) {
      if (remote != lease) {
        throw GitError('remote branch $branch changed since the last fetch; '
            'refusing to force push (sync again)');
      }
    } else if (remote != null &&
        remote != local &&
        !(repo.odb.has(remote) && isAncestor(repo.odb, remote, local))) {
      throw GitError(
          'push rejected: remote branch $branch has new commits (non-fast-forward)');
    }
    if (remote != local) {
      final haves = {
        ...session.refs.values,
        ...repo.refs.list(_tracking).values
      };
      final objects = objectsToSend(repo.odb, [local], haves);
      await session
          .push([RefUpdate(ref, remote ?? zeroId, local)], buildPack(objects));
    }
    repo.refs.update('$_tracking$branch', local);
  } finally {
    await session.close();
  }
}

/// Clones [transport] into [dir] checking out [branch]. An empty remote
/// leaves [branch] unborn; a remote without [branch] is an error.
Future<void> cloneInto(
    String url, Transport transport, String dir, String branch) async {
  final d = Directory(dir);
  if (d.existsSync() && d.listSync().isNotEmpty) {
    throw GitError("destination '$dir' already exists and is not empty");
  }
  final existed = d.existsSync();
  Repository? repo;
  try {
    repo = Repository.init(dir, branch: branch);
    final cfg = repo.config;
    cfg.set('remote', 'origin', 'url', url);
    cfg.set('remote', 'origin', 'fetch', '+refs/heads/*:refs/remotes/origin/*');
    cfg.save();
    final heads = await fetchOrigin(repo, transport);
    if (heads.isEmpty) return;
    final id = heads['refs/heads/$branch'];
    if (id == null) {
      throw GitError("remote has no branch '$branch' "
          '(available: ${heads.keys.map((k) => k.substring(11)).join(', ')})');
    }
    repo.refs.update('refs/heads/$branch', id);
    cfg.set('branch', branch, 'remote', 'origin');
    cfg.set('branch', branch, 'merge', 'refs/heads/$branch');
    cfg.save();
    repo.checkout({}, repo.treeOfCommit(id));
  } catch (_) {
    repo?.close();
    repo = null;
    try {
      if (existed) {
        for (final e in d.listSync()) {
          e.deleteSync(recursive: true);
        }
      } else if (d.existsSync()) {
        d.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Best effort.
    }
    rethrow;
  } finally {
    repo?.close();
  }
}

/// Result of replaying local commits onto another commit.
class RebaseResult {
  RebaseResult(this.tip, this.conflicts);
  final String? tip;
  final List<String> conflicts;
}

/// Replays the commits of [local] that are not in [onto] on top of
/// [onto], in memory. Nothing but new objects is written.
RebaseResult rebaseCommits(
    Repository repo, String local, String onto, Signature committer) {
  final odb = repo.odb;
  final replay = commitsToReplay(odb, local, onto);
  var tip = onto;
  var current = repo.treeOfCommit(onto);
  for (final id in replay) {
    final c = odb.readCommit(id);
    final base = c.parents.isEmpty
        ? <String, TreeEntry>{}
        : repo.treeOfCommit(c.parents.first);
    final theirs = odb.flattenTree(c.tree);
    final m = mergeTrees(odb, base, current, theirs);
    if (m.conflicts.isNotEmpty) return RebaseResult(null, m.conflicts);
    if (_flatEqual(m.tree, current)) continue; // already upstream
    final tree = odb.writeTreeFromFlat(m.tree);
    final commit = Commit(
      tree: tree,
      parents: [tip],
      author: c.author,
      committer: committer,
      message: c.message,
    );
    tip = odb.write(ObjectType.commit, commit.serialize());
    current = m.tree;
  }
  return RebaseResult(tip, const []);
}

bool _flatEqual(Map<String, TreeEntry> a, Map<String, TreeEntry> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null || o.id != e.value.id || o.mode != e.value.mode) return false;
  }
  return true;
}

/// Moves `refs/heads/<branch>` to [target], updating the working tree and
/// index when HEAD is on that branch.
void moveBranch(Repository repo, String branch, String target) {
  final ref = 'refs/heads/$branch';
  final old = repo.refs.resolve(ref);
  if (repo.headRef == ref && !repo.isBare) {
    repo.checkout(repo.treeOfCommit(old), repo.treeOfCommit(target));
  }
  repo.refs.update(ref, target);
}
