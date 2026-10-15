import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'local_ops.dart';
import 'objects.dart';
import 'remote.dart';
import 'repository.dart';
import 'transport/transport.dart';
import 'util.dart';

enum AuthMethod { none, httpsToken, sshKey, sshAgent }

/// Credentials for remote operations.
class GitAuth {
  GitAuth({
    this.method = AuthMethod.none,
    this.username,
    this.password,
    this.sshKeyPath,
    this.sshPassphrase,
  });

  AuthMethod method;

  /// HTTPS user name (defaults to `git` when empty) or SSH user override.
  String? username;

  /// HTTPS token or password.
  String? password;

  /// Path of an OpenSSH/PEM private key file.
  String? sshKeyPath;

  /// Passphrase of [sshKeyPath], if encrypted.
  String? sshPassphrase;
}

enum SyncOutcome {
  noRemote,
  dirtyTree,
  upToDate,
  fastForwarded,
  pushed,
  rebased,
  conflict
}

class SyncResult {
  SyncResult(this.outcome, {this.message, this.conflictedFiles = const []});
  SyncOutcome outcome;
  String? message;
  List<String> conflictedFiles;

  @override
  String toString() =>
      'SyncResult($outcome${message == null ? '' : ', $message'}'
      '${conflictedFiles.isEmpty ? '' : ', $conflictedFiles'})';
}

enum ConflictResolution { keepRemote, forcePushLocal, abort }

/// Git operations used by GitMarker. Every method runs its blocking work on
/// a background isolate (unless [useIsolates] is false) and reports
/// failures as [GitException].
class GitBackend {
  GitBackend({
    GitAuth? auth,
    this.authorName = 'GitMarker',
    this.authorEmail = 'gitmarker@localhost',
    this.knownHostsPath,
    this.networkTimeout = const Duration(minutes: 2),
    this.useIsolates = true,
  }) : auth = auth ?? GitAuth();

  final GitAuth auth;
  final String authorName;
  final String authorEmail;

  /// JSON file `{host: fingerprint}` with pinned SSH host keys.
  final String? knownHostsPath;

  /// Idle timeout for network operations.
  final Duration networkTimeout;

  /// Run operations in `Isolate.run` (keeps a Flutter UI responsive).
  final bool useIsolates;

  Future<T> _run<T>(String op, FutureOr<T> Function() body) async {
    Future<T> guarded() async {
      try {
        return await body();
      } on GitException {
        rethrow;
      } on GitError catch (e) {
        throw GitException(op, e.message);
      } on FileSystemException catch (e) {
        throw GitException(
            op,
            '${e.message}${e.path == null ? '' : ': ${e.path}'}'
            '${e.osError == null ? '' : ' (${e.osError!.message})'}');
      } on FormatException catch (e) {
        throw GitException(op, 'corrupt data: ${e.message}');
      } on TimeoutException {
        throw GitException(
            op, 'network timeout after ${networkTimeout.inSeconds}s');
      }
    }

    if (!useIsolates) return guarded();
    return Isolate.run(guarded, debugName: 'dartgit:$op');
  }

  T _withRepo<T>(String dir, T Function(Repository repo) f) {
    final repo = Repository.open(dir);
    try {
      return f(repo);
    } finally {
      repo.close();
    }
  }

  Signature _signature() => Signature.now(authorName, authorEmail);

  Future<bool> isRepository(String dir) => _run('isRepository', () {
        final r = Repository.tryOpen(dir);
        r?.close();
        return r != null && !r.isBare;
      });

  Future<void> init(String dir, {required String branch}) =>
      _run('init', () => Repository.init(dir, branch: branch).close());

  Future<String?> remoteUrl(String dir) => _run('remoteUrl',
      () => _withRepo(dir, (r) => r.config.get('remote', 'origin', 'url')));

  Future<void> setRemoteUrl(String dir, String url) => _run('setRemoteUrl', () {
        _withRepo(dir, (r) {
          final c = r.config;
          c.set('remote', 'origin', 'url', url);
          if (c.get('remote', 'origin', 'fetch') == null) {
            c.set('remote', 'origin', 'fetch',
                '+refs/heads/*:refs/remotes/origin/*');
          }
          c.save();
        });
      });

  Future<({bool clean, int unpushed})> status(String dir, String branch) =>
      _run(
          'status',
          () => _withRepo(dir, (r) {
                final clean = isClean(r);
                final local = r.refs.resolve('refs/heads/$branch');
                final remote = r.refs.resolve('refs/remotes/origin/$branch');
                final unpushed = local == null
                    ? 0
                    : aheadBehindCommits(r.odb, local, remote).ahead;
                return (clean: clean, unpushed: unpushed);
              }));

  /// Commits and pushed/fetched-commit counts between `refs/heads/<branch>`
  /// and `refs/remotes/origin/<branch>`.
  Future<({int ahead, int behind})> aheadBehind(String dir, String branch) =>
      _run(
          'aheadBehind',
          () => _withRepo(dir, (r) {
                final local = r.refs.resolve('refs/heads/$branch');
                final remote = r.refs.resolve('refs/remotes/origin/$branch');
                return aheadBehindCommits(r.odb, local, remote);
              }));

  Transport _transport(String url) => openTransport(
      url,
      TransportOptions(
          auth: auth, knownHostsPath: knownHostsPath, timeout: networkTimeout));

  /// Clones [url] into [dir] and checks out [branch]. An empty remote is
  /// fine (the branch stays unborn); a remote whose branches do not include
  /// [branch] is an error and [dir] is removed.
  Future<void> clone(String url, String dir, {required String branch}) =>
      _run('clone', () => cloneInto(url, _transport(url), dir, branch));

  Future<SyncResult> sync(String dir, String branch) => _run('sync', () async {
        final repo = Repository.open(dir);
        try {
          return await _sync(repo, branch);
        } finally {
          repo.close();
        }
      });

  Future<SyncResult> _sync(Repository repo, String branch) async {
    final url = repo.config.get('remote', 'origin', 'url');
    if (url == null || url.isEmpty) return SyncResult(SyncOutcome.noRemote);
    if (!isClean(repo)) {
      return SyncResult(SyncOutcome.dirtyTree,
          message: 'uncommitted changes', conflictedFiles: changedPaths(repo));
    }
    final t = _transport(url);
    await fetchOrigin(repo, t);
    final ref = 'refs/heads/$branch';
    final local = repo.refs.resolve(ref);
    final remote = repo.refs.resolve('refs/remotes/origin/$branch');
    if (remote == null) {
      if (local == null) return SyncResult(SyncOutcome.upToDate);
      await pushBranch(repo, t, branch);
      return SyncResult(SyncOutcome.pushed,
          message: 'created remote branch $branch');
    }
    if (local == null) {
      moveBranch(repo, branch, remote);
      return SyncResult(SyncOutcome.fastForwarded);
    }
    if (local == remote) return SyncResult(SyncOutcome.upToDate);
    final ab = aheadBehindCommits(repo.odb, local, remote);
    if (ab.ahead == 0) {
      moveBranch(repo, branch, remote);
      return SyncResult(SyncOutcome.fastForwarded,
          message: '${ab.behind} new commit(s)');
    }
    if (ab.behind == 0) {
      await pushBranch(repo, t, branch);
      return SyncResult(SyncOutcome.pushed,
          message: '${ab.ahead} commit(s) pushed');
    }
    final r = rebaseCommits(repo, local, remote, _signature());
    if (r.tip == null) {
      return SyncResult(SyncOutcome.conflict,
          message: 'local and remote changes conflict',
          conflictedFiles: r.conflicts);
    }
    moveBranch(repo, branch, r.tip!);
    if (r.tip != remote) await pushBranch(repo, t, branch);
    return SyncResult(SyncOutcome.rebased,
        message:
            '${ab.ahead} local commit(s) rebased onto ${ab.behind} remote commit(s)');
  }

  /// Resolves a conflict reported by [sync].
  Future<SyncResult> resolve(String dir, String branch, ConflictResolution r) =>
      _run('resolve', () async {
        final repo = Repository.open(dir);
        try {
          switch (r) {
            case ConflictResolution.abort:
              // sync never leaves a half-done rebase behind.
              return SyncResult(SyncOutcome.upToDate,
                  message: 'aborted; nothing changed');
            case ConflictResolution.keepRemote:
              final url = repo.config.get('remote', 'origin', 'url');
              if (url == null || url.isEmpty)
                return SyncResult(SyncOutcome.noRemote);
              if (!isClean(repo)) {
                return SyncResult(SyncOutcome.dirtyTree,
                    message: 'uncommitted changes',
                    conflictedFiles: changedPaths(repo));
              }
              await fetchOrigin(repo, _transport(url));
              final remote = repo.refs.resolve('refs/remotes/origin/$branch');
              if (remote == null)
                throw GitError("remote has no branch '$branch'");
              moveBranch(repo, branch, remote);
              return SyncResult(SyncOutcome.fastForwarded,
                  message: 'local commits discarded; reset to remote');
            case ConflictResolution.forcePushLocal:
              final url = repo.config.get('remote', 'origin', 'url');
              if (url == null || url.isEmpty)
                return SyncResult(SyncOutcome.noRemote);
              final lease = repo.refs.resolve('refs/remotes/origin/$branch');
              await pushBranch(repo, _transport(url), branch,
                  force: true, lease: lease);
              return SyncResult(SyncOutcome.pushed,
                  message: 'remote overwritten with local');
          }
        } finally {
          repo.close();
        }
      });

  Future<bool> commit(String dir, String message, {List<String>? paths}) =>
      _run(
          'commit',
          () => _withRepo(dir, (r) {
                final sig = _signature();
                return commitChanges(r, message, paths: paths, author: sig);
              }));

  Future<List<Revision>> fileHistory(String dir, String path) =>
      _run('fileHistory', () => _withRepo(dir, (r) => fileHistoryOf(r, path)));

  Future<String?> showFile(String dir, String commit, String path) => _run(
      'showFile',
      () => _withRepo(dir, (r) {
            final id = resolveCommitish(r, commit);
            if (id == null) return null;
            final o = r.odb.tryRead(id);
            if (o == null || o.type != ObjectType.commit) return null;
            final e = r.odb
                .lookupPath(Commit.parse(o.data).tree, normalizePath(path));
            if (e == null || e.isTree) return null;
            return utf8.decode(r.odb.read(e.id).data, allowMalformed: true);
          }));
}

({int ahead, int behind}) aheadBehindCommits(
    ObjectDatabase odb, String? local, String? remote) {
  if (local == null) {
    return (
      ahead: 0,
      behind: remote == null ? 0 : reachable(odb, [remote]).length
    );
  }
  return aheadBehind(odb, local, remote);
}

List<Revision> fileHistoryOf(Repository r, String path) => fileHistory(r, path);
