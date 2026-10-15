import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'credentials.dart';
import 'hash.dart';
import 'history.dart' as history;
import 'objects.dart';
import 'rebase.dart' as rebase_;
import 'remote.dart' as remote_;
import 'repository.dart';
import 'transport/transport.dart';
import 'util.dart';
import 'worktree.dart' as worktree;

/// Git commands on repositories in local directories. Each method mirrors
/// the `git` command named in its documentation, runs on a background
/// isolate (unless [useIsolates] is false) and throws [GitException] on
/// failure.
class Git {
  Git({
    this.credentials = const NoCredentials(),
    this.verifyHostKey,
    this.authorName,
    this.authorEmail,
    this.networkTimeout = const Duration(minutes: 2),
    this.useIsolates = true,
  });

  /// Credentials for remote operations.
  final Credentials credentials;

  /// Decides about SSH host keys; without it every SSH connection fails
  /// with "Host key verification failed", like `ssh` with an unknown host.
  final HostKeyVerifier? verifyHostKey;

  /// Identity for commits and reflogs (`user.name`, `user.email`); when
  /// null, the repository's config is used.
  final String? authorName;
  final String? authorEmail;

  /// Idle timeout for network operations: a connect or read that waits
  /// longer fails with a [GitException].
  final Duration networkTimeout;

  /// Run each command in `Isolate.run` (keeps a Flutter UI responsive).
  final bool useIsolates;

  Future<T> _run<T>(String op, FutureOr<T> Function() body) {
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
            op, 'network timeout after ${networkTimeout.inSeconds} s');
      } on SocketException catch (e) {
        throw GitException(
            op,
            'network error: ${e.message}'
            '${e.osError == null ? '' : ' (${e.osError!.message})'}');
      } on TlsException catch (e) {
        throw GitException(op, 'TLS error: ${e.message}');
      } on IOException catch (e) {
        throw GitException(op, 'I/O error: $e');
      }
    }

    return useIsolates
        ? Isolate.run(guarded, debugName: 'dartgit:$op')
        : guarded();
  }

  Future<T> _repo<T>(
      String op, String dir, FutureOr<T> Function(Repository repo) body) {
    return _run(op, () async {
      final repo = Repository.open(dir)..identity = _identityOrNull(dir);
      try {
        return await body(repo);
      } finally {
        repo.close();
      }
    });
  }

  Signature? _identityOrNull(String dir) {
    var name = authorName, email = authorEmail;
    if (name == null || email == null) {
      final repo = Repository.tryOpen(dir);
      name ??= repo?.config.get('user', null, 'name');
      email ??= repo?.config.get('user', null, 'email');
      repo?.close();
    }
    if (name == null || email == null) return null;
    return Signature.now(name, email);
  }

  Signature _identity(Repository repo) {
    final id = repo.identity;
    if (id == null) {
      throw GitError('Author identity unknown: set authorName and '
          'authorEmail, or user.name and user.email in the config');
    }
    return id;
  }

  Transport _transport(Repository repo, String remote) {
    final url = remote_.remoteGetUrl(repo, remote);
    if (url == null) {
      throw GitError("'$remote' does not appear to be a git repository");
    }
    return _transportFor(url);
  }

  Transport _transportFor(String url) => openTransport(
      url,
      TransportOptions(
          credentials: credentials,
          verifyHostKey: verifyHostKey,
          timeout: networkTimeout));

  // -------------------------------------------------------------------------
  // Setting up

  /// `git init [--bare] [-b <branch>] [--object-format=<format>] <dir>`
  /// (`--object-format=sha256` creates a SHA-256 repository).
  Future<void> init(String dir,
          {String initialBranch = 'master',
          bool bare = false,
          ObjectFormat objectFormat = ObjectFormat.sha1}) =>
      _run(
          'init',
          () => Repository.init(dir,
                  branch: initialBranch, bare: bare, format: objectFormat)
              .close());

  /// `git rev-parse --show-object-format`: the repository's object format.
  Future<ObjectFormat> objectFormat(String dir) =>
      _repo('rev-parse', dir, (r) => r.format);

  /// Whether [dir] is the top of a Git working tree (bare repositories and
  /// subdirectories do not count).
  Future<bool> isRepository(String dir) => _run('rev-parse', () {
        final r = Repository.tryOpen(dir);
        r?.close();
        return r != null && !r.isBare;
      });

  /// `git clone [-b <branch>] <url> <dir>`.
  Future<void> clone(String url, String dir, {String? branch}) => _run(
      'clone',
      () => remote_.clone(url, _transportFor(url), dir,
          branch: branch,
          identity: authorName == null || authorEmail == null
              ? null
              : Signature.now(authorName!, authorEmail!)));

  /// `git remote get-url <remote>`; null when it does not exist.
  Future<String?> remoteGetUrl(String dir, {String remote = 'origin'}) =>
      _repo('remote', dir, (r) => remote_.remoteGetUrl(r, remote));

  /// `git remote add <remote> <url>`.
  Future<void> remoteAdd(String dir, String url, {String remote = 'origin'}) =>
      _repo('remote', dir, (r) => remote_.remoteAdd(r, remote, url));

  /// `git remote set-url <remote> <url>`.
  Future<void> remoteSetUrl(String dir, String url,
          {String remote = 'origin'}) =>
      _repo('remote', dir, (r) => remote_.remoteSetUrl(r, remote, url));

  /// `git remote remove <remote>`.
  Future<void> remoteRemove(String dir, {String remote = 'origin'}) =>
      _repo('remote', dir, (r) => remote_.remoteRemove(r, remote));

  // -------------------------------------------------------------------------
  // Working tree

  /// `git status --porcelain --untracked-files=all`; empty when clean.
  Future<List<worktree.StatusEntry>> status(String dir) =>
      _repo('status', dir, worktree.status);

  /// `git add -A -- <pathspecs>` (`.` stages everything).
  Future<void> add(String dir, List<String> pathspecs) =>
      _repo('add', dir, (r) => worktree.add(r, pathspecs));

  /// `git commit -m <message>`, or with [only]
  /// `git commit --only -m <message> -- <only>` (new files under [only] are
  /// included). Returns the new commit id, or null when there is nothing to
  /// commit.
  Future<String?> commit(String dir, String message, {List<String>? only}) =>
      _repo('commit', dir,
          (r) => worktree.commit(r, message, only: only, author: _identity(r)));

  /// `git reset --hard <rev>`.
  Future<void> resetHard(String dir, String rev) => _repo('reset', dir, (r) {
        final id = history.revParse(r, rev);
        if (id == null) throw GitError("ambiguous argument '$rev'");
        worktree.resetHard(r, id, reflogMessage: 'reset: moving to $rev');
      });

  /// `git rebase <upstream>`; a conflicting rebase is aborted (see
  /// [rebase_.rebase]).
  Future<rebase_.RebaseResult> rebase(String dir, String upstream) => _repo(
      'rebase',
      dir,
      (r) => rebase_.rebase(r, upstream, committer: _identity(r)));

  // -------------------------------------------------------------------------
  // History

  /// `git rev-parse --verify --quiet <rev>^{commit}`; null when unknown.
  Future<String?> revParse(String dir, String rev) =>
      _repo('rev-parse', dir, (r) => history.revParse(r, rev));

  /// `git rev-list --count <rev> [^<exclude>]`.
  Future<int> revListCount(String dir, String rev, {String? exclude}) =>
      _repo('rev-list', dir, (r) {
        String resolve(String x) =>
            history.revParse(r, x) ??
            (throw GitError("ambiguous argument '$x'"));
        return history.countCommits(r.odb, resolve(rev),
            exclude: exclude == null ? null : resolve(exclude));
      });

  /// `git log --first-parent [--follow] [<rev>] [-- <path>]`.
  Future<List<history.LogEntry>> log(String dir,
          {String rev = 'HEAD', String? path, bool follow = false}) =>
      _repo('log', dir,
          (r) => history.log(r, rev: rev, path: path, follow: follow));

  /// `git show <rev>:<path>`; null when it does not exist.
  Future<Uint8List?> show(String dir, String rev, String path) =>
      _repo('show', dir, (r) => history.show(r, rev, path));

  // -------------------------------------------------------------------------
  // Remotes

  /// `git fetch [--prune] <remote>`.
  Future<void> fetch(String dir,
          {String remote = 'origin', bool prune = false}) =>
      _repo('fetch', dir, (r) async {
        await remote_.fetch(r, remote, _transport(r, remote), prune: prune);
      });

  /// `git push [--force-with-lease] <remote> <refspec>`; [refspec] is
  /// `<src>[:<dst>]`, e.g. `main` or `HEAD:notes`.
  Future<void> push(String dir, String refspec,
          {String remote = 'origin', bool forceWithLease = false}) =>
      _repo(
          'push',
          dir,
          (r) => remote_.push(r, remote, _transport(r, remote), refspec,
              forceWithLease: forceWithLease));
}
