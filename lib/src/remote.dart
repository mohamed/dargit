/// Commands that talk to a remote: `clone`, `fetch`, `push`, plus the
/// `remote` configuration commands.
library;

import 'dart:io';

import 'hash.dart';
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
  final head = File(repo.path('${_tracking(remote)}HEAD'));
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
  FetchResult(this.branches, this.head, this.headId);

  /// `refs/heads/*` of the remote -> commit id.
  final Map<String, String> branches;

  /// The branch the remote HEAD points at, if advertised.
  final String? head;

  /// The commit of the remote HEAD (fetched only by clone).
  final String? headId;
}

/// `git fetch [--prune] <remote>` with the default refspec
/// `+refs/heads/*:refs/remotes/<remote>/*` (tags are not fetched).
Future<FetchResult> fetch(Repository repo, String remote, Transport transport,
        {bool prune = false}) async =>
    _fetch(repo, remote, await transport.openUpload(),
        prune: prune, reflog: 'fetch${prune ? ' --prune' : ''} $remote');

/// `git ls-remote <url>`: the remote's branches and tags (and `HEAD` when
/// it points at a commit, detached or not).
Future<Map<String, String>> lsRemote(Transport transport) async {
  final session = await transport.openUpload();
  try {
    final head = session.headId;
    return {if (head != null) 'HEAD': head, ...session.refs};
  } finally {
    await session.close();
  }
}

/// Refuses a remote whose object format differs from [repo]'s, like git
/// ("mismatched object format").
void _checkFormat(Repository repo, ObjectFormat theirs) {
  if (theirs != repo.format) {
    throw GitError('the remote uses ${theirs.name} object ids but this '
        'repository uses ${repo.format.name}');
  }
}

/// Fetches through an open [session] and closes it.
Future<FetchResult> _fetch(
    Repository repo, String remote, UploadSession session,
    {bool prune = false, required String? reflog, bool head = false}) async {
  try {
    _checkFormat(repo, session.format);
    final heads = <String, String>{
      for (final e in session.refs.entries)
        if (e.key.startsWith('refs/heads/')) e.key: e.value,
    };
    final headId = head ? session.headId : null;
    final wants = {...heads.values, if (headId != null) headId}
        .where((id) => !repo.odb.has(id))
        .toList();
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
      if (reflog == null) {
        repo.refs.update(local, id); // git clone logs no tracking refs
        return;
      }
      final how = old == null
          ? 'storing head'
          : isAncestor(repo.odb, old, id)
              ? 'fast-forward'
              : 'forced-update';
      repo.updateRef(local, id, '$reflog: $how');
    });
    if (prune) {
      for (final name in existing.keys) {
        if (!heads.containsKey('refs/heads/${name.substring(prefix.length)}')) {
          repo.updateRef(name, null, '');
        }
      }
    }
    return FetchResult(heads, session.head, headId);
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
    _checkFormat(repo, session.format);
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
      await session.push([RefUpdate(ref, theirs ?? repo.format.zeroId, local)],
          buildPack(objectsToSend(repo.odb, [local], haves), repo.format));
    }
    if (repo.refs.resolve(tracking) != local) {
      repo.updateRef(tracking, local, 'update by push');
    }
  } finally {
    await session.close();
  }
}

/// `git clone [-b <branch>] <url> <dir>`. Without [branch] the remote's
/// HEAD is checked out, and an empty remote gives an unborn branch. When
/// the remote has no [branch] (an empty remote included), the clone fails
/// and [dir] is removed, like git.
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
    // The new repository takes the remote's object format.
    final session = await transport.openUpload();
    try {
      repo = Repository.init(dir,
          branch: branch ?? 'master', format: session.format)
        ..identity = identity;
      remoteAdd(repo, 'origin', url);
    } catch (_) {
      await session.close();
      rethrow;
    }
    final fetched =
        await _fetch(repo, 'origin', session, reflog: null, head: true);
    final heads = fetched.branches;
    if (branch != null && !heads.containsKey('refs/heads/$branch')) {
      throw GitError('Remote branch $branch not found in upstream origin');
    }
    final target = branch == null ? fetched.head : 'refs/heads/$branch';
    if (target == null && fetched.headId != null) {
      // A detached remote HEAD is cloned as a detached HEAD.
      repo.updateRef('HEAD', fetched.headId, 'clone: from $url');
      repo.checkout({}, repo.treeOfCommit(fetched.headId));
      return;
    }
    final id = target == null ? null : heads[target];
    if (id == null) {
      // An empty remote ("You appear to have cloned an empty repository")
      // or a remote HEAD on a missing branch ("remote HEAD refers to
      // nonexistent ref"): HEAD names that unborn branch, else the default
      // branch, and nothing is checked out.
      if (target != null) repo.refs.setSymbolic('HEAD', target);
      final head = repo.headRef!;
      repo.config
        ..set(
            'branch', head.substring('refs/heads/'.length), 'remote', 'origin')
        ..set('branch', head.substring('refs/heads/'.length), 'merge', head)
        ..save();
      return;
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
