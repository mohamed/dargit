/// Commands that talk to a remote: `clone`, `fetch`, `push`, plus the
/// `remote` configuration commands.
library;

import 'dart:io';

import 'history.dart';
import 'objects.dart';
import 'pack.dart';
import 'packgen.dart';
import 'repository.dart';
import 'transport/transport.dart';
import 'util.dart';

String _tracking(String remote) => 'refs/remotes/$remote/';

/// `git remote get-url <remote>`; null when the remote is not configured.
String? remoteGetUrl(Repository repo, String remote) {
  final url = repo.config.get('remote', remote, 'url');
  return url == null || url.isEmpty ? null : url;
}

/// `git remote add <remote> <url>`.
void remoteAdd(Repository repo, String remote, String url) {
  if (remoteGetUrl(repo, remote) != null) {
    throw GitError('remote $remote already exists');
  }
  repo.config
    ..set('remote', remote, 'url', url)
    ..set('remote', remote, 'fetch', '+refs/heads/*:${_tracking(remote)}*')
    ..save();
}

/// `git remote set-url <remote> <url>`.
void remoteSetUrl(Repository repo, String remote, String url) {
  if (remoteGetUrl(repo, remote) == null) {
    throw GitError("No such remote '$remote'");
  }
  repo.config
    ..set('remote', remote, 'url', url)
    ..save();
}

/// `git remote remove <remote>`: drops its configuration and its
/// remote-tracking refs.
void remoteRemove(Repository repo, String remote) {
  if (remoteGetUrl(repo, remote) == null) {
    throw GitError("No such remote: '$remote'");
  }
  final cfg = repo.config..removeSection('remote', remote);
  for (final b in repo.refs.list('refs/heads/').keys) {
    final name = b.substring('refs/heads/'.length);
    if (cfg.get('branch', name, 'remote') == remote) {
      cfg.removeSection('branch', name);
    }
  }
  cfg.save();
  for (final ref in repo.refs.list(_tracking(remote)).keys) {
    repo.updateRef(ref, null, '');
  }
  final head = File(joinPath(repo.gitDir, '${_tracking(remote)}HEAD'));
  if (head.existsSync()) head.deleteSync();
}

/// Commits we tell the server we have: tips of local and tracking branches
/// plus a few first-parent ancestors.
List<String> _haves(Repository repo) {
  final out = <String>{};
  final tips = {
    ...repo.refs.list('refs/heads/').values,
    ...repo.refs.list('refs/remotes/').values,
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

/// What the remote advertised during a fetch.
class FetchResult {
  FetchResult(this.branches, this.head);

  /// `refs/heads/*` of the remote -> commit id.
  final Map<String, String> branches;

  /// The branch the remote HEAD points at, if advertised.
  final String? head;
}

/// `git fetch [--prune] <remote>` with the default refspec
/// `+refs/heads/*:refs/remotes/<remote>/*` (tags are not fetched).
Future<FetchResult> fetch(Repository repo, String remote, Transport transport,
    {bool prune = false, String reflogPrefix = 'fetch'}) async {
  final session = await transport.openUpload();
  try {
    final heads = <String, String>{
      for (final e in session.refs.entries)
        if (e.key.startsWith('refs/heads/')) e.key: e.value,
    };
    final wants =
        heads.values.where((id) => !repo.odb.has(id)).toSet().toList();
    if (wants.isNotEmpty) {
      storePack(repo.odb, await session.fetchPack(wants, _haves(repo)));
      for (final w in wants) {
        if (!repo.odb.has(w)) throw GitError('remote sent an incomplete pack');
      }
    }
    final prefix = _tracking(remote);
    final existing = repo.refs.list(prefix);
    heads.forEach((name, id) {
      final local = '$prefix${name.substring('refs/heads/'.length)}';
      final old = existing[local];
      if (old == id) return;
      final how = old == null
          ? 'storing head'
          : isAncestor(repo.odb, old, id)
              ? 'fast-forward'
              : 'forced-update';
      repo.updateRef(local, id, '$reflogPrefix: $how');
    });
    if (prune) {
      for (final name in existing.keys) {
        if (!heads.containsKey('refs/heads/${name.substring(prefix.length)}')) {
          repo.updateRef(name, null, '');
        }
      }
    }
    return FetchResult(heads, session.head);
  } finally {
    await session.close();
  }
}

/// `git push [--force-with-lease] <remote> <src>[:<dst>]`. [src] is a
/// branch, `HEAD` or another revision; [dst] defaults to [src] when that
/// is a branch, and to the current branch for `HEAD`. Without
/// [forceWithLease] the update must be a fast-forward; with it, the remote
/// branch must still be where `refs/remotes/<remote>/<dst>` says (git's
/// default lease). Updates that remote-tracking ref on success.
Future<void> push(
    Repository repo, String remote, Transport transport, String refspec,
    {bool forceWithLease = false}) async {
  final colon = refspec.indexOf(':');
  final src = colon < 0 ? refspec : refspec.substring(0, colon);
  var dst = colon < 0 ? null : refspec.substring(colon + 1);
  final local = revParse(repo, src);
  if (local == null) {
    throw GitError('src refspec $src does not match any');
  }
  if (dst == null) {
    if (src == 'HEAD') {
      dst = repo.headRef;
    } else if (repo.refs.resolve('refs/heads/$src') != null) {
      dst = src;
    } else if (src.startsWith('refs/heads/')) {
      dst = src;
    }
    if (dst == null) throw GitError('The destination of $refspec is unknown');
  }
  final ref = dst.startsWith('refs/') ? dst : 'refs/heads/$dst';
  if (!ref.startsWith('refs/heads/')) {
    throw GitError('only branches can be pushed: $ref');
  }
  final branch = ref.substring('refs/heads/'.length);
  final tracking = '${_tracking(remote)}$branch';
  final session = await transport.openReceive();
  try {
    final theirs = session.refs[ref];
    if (forceWithLease) {
      if (theirs != repo.refs.resolve(tracking)) {
        throw GitError('! [rejected] $src -> $branch (stale info)');
      }
    } else if (theirs != null && theirs != local) {
      if (!repo.odb.has(theirs)) {
        throw GitError('! [rejected] $src -> $branch (fetch first)');
      }
      if (!isAncestor(repo.odb, theirs, local)) {
        throw GitError('! [rejected] $src -> $branch (non-fast-forward)');
      }
    }
    if (theirs != local) {
      final haves = {
        ...session.refs.values,
        ...repo.refs.list(_tracking(remote)).values,
      };
      await session.push([RefUpdate(ref, theirs ?? zeroId, local)],
          buildPack(objectsToSend(repo.odb, [local], haves)));
    }
    if (repo.refs.resolve(tracking) != local) {
      repo.updateRef(tracking, local, 'update by push');
    }
  } finally {
    await session.close();
  }
}

/// `git clone [-b <branch>] <url> <dir>`. Without [branch] the remote's
/// HEAD is checked out. An empty remote leaves the branch unborn. When the
/// remote has branches but not [branch], the clone fails and [dir] is
/// removed, like git.
Future<void> clone(String url, Transport transport, String dir,
    {String? branch, Signature? identity}) async {
  final d = Directory(dir);
  if (d.existsSync() && d.listSync().isNotEmpty) {
    throw GitError(
        "destination path '$dir' already exists and is not an empty directory");
  }
  final existed = d.existsSync();
  Repository? repo;
  try {
    repo = Repository.init(dir, branch: branch ?? 'master')
      ..identity = identity;
    remoteAdd(repo, 'origin', url);
    final fetched =
        await fetch(repo, 'origin', transport, reflogPrefix: 'clone');
    final heads = fetched.branches;
    if (heads.isEmpty) return; // empty repository
    final target = branch == null ? fetched.head : 'refs/heads/$branch';
    final id = target == null ? null : heads[target];
    if (id == null) {
      throw GitError(branch == null
          ? 'remote HEAD refers to nonexistent ref, unable to checkout'
          : 'Remote branch $branch not found in upstream origin '
              '(branches: ${heads.keys.map((k) => k.substring(11)).join(', ')})');
    }
    final name = target!.substring('refs/heads/'.length);
    repo.refs.setSymbolic('HEAD', target);
    if (fetched.head != null) {
      repo.refs.setSymbolic(
          'refs/remotes/origin/HEAD',
          'refs/remotes/origin/'
              '${fetched.head!.substring('refs/heads/'.length)}');
    }
    repo.updateRef(target, id, 'clone: from $url');
    repo.config
      ..set('branch', name, 'remote', 'origin')
      ..set('branch', name, 'merge', target)
      ..save();
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
