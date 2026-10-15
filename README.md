# dartgit

A small, pure-Dart Git implementation for note-taking apps: no Flutter, no
FFI, no native libraries. It was written to replace libgit2 (git2dart) in
GitMarker, so that the Android build has no prebuilt `.so` files (Google
Play's 16 KB page-size requirement, F-Droid's no-prebuilt-binaries policy).

It implements what a Markdown-notes app needs and nothing more. Repositories
it writes are ordinary Git repositories: the Git CLI can read them, and
`git fsck --strict` and `git status` stay clean.

## Scope

- **Repositories**: `init` (initial branch name), detection, `.git` file
  indirection, bare repositories as remotes.
- **Objects**: loose objects (zlib), packfiles with `.idx` v2, OFS_DELTA and
  REF_DELTA, SHA-1.
- **Refs**: loose refs, `packed-refs`, symbolic `HEAD` (including unborn
  branches), remote-tracking refs `refs/remotes/origin/<branch>`.
- **Index**: v2/v3 read, v2 write.
- **Commit**: everything (`git add -A` semantics, honouring `.gitignore`) or
  only given paths, leaving other staged changes untouched.
- **Status**: clean flag plus the number of unpushed commits; ahead/behind.
- **History**: `fileHistory` follows renames along first parents (like
  `git log --follow --first-parent`), `showFile` reads a file at a commit.
- **Remotes**: clone, fetch (with prune), push (fast-forward, or
  force-with-lease), `sync` (fast-forward / push / rebase local commits with
  a line-based 3-way merge), conflict detection with no side effects, and
  `resolve` (keep remote, force-push local, abort).
- **Transports** (smart protocol v0): local paths and `file://`, HTTP(S)
  with a token as Basic auth, SSH via [`dartssh2`](https://pub.dev/packages/dartssh2)
  (private key file with optional passphrase, SSH agent on desktop,
  `user@host:path` and `ssh://` URLs, host keys pinned on first use).
- Every operation runs in a background isolate, and network operations fail
  with a clear `GitException` after an idle timeout (2 minutes by default).

## Non-goals

SHA-256 repositories, submodules, LFS, merges other than rebasing local
commits, tags, hooks, reflogs, CRLF conversion, sparse checkout, shallow
clones, protocol v2 and the dumb HTTP protocol. See [STATUS.md](STATUS.md)
for the design decisions and known limitations.

## Usage

```dart
import 'package:dartgit/dartgit.dart';

Future<void> main() async {
  final git = GitBackend(
    auth: GitAuth(method: AuthMethod.httpsToken, password: 'ghp_...'),
    authorName: 'Ada',
    authorEmail: 'ada@example.com',
    knownHostsPath: '/path/to/known_hosts.json', // used for SSH
    networkTimeout: const Duration(minutes: 2),
  );

  const dir = '/path/to/notes';
  if (!await git.isRepository(dir)) {
    await git.clone('https://github.com/me/notes.git', dir, branch: 'main');
  }

  // ... edit files ...
  await git.commit(dir, 'Edit today.md', paths: ['today.md']);
  await git.commit(dir, 'Save everything'); // returns false if nothing changed

  final st = await git.status(dir, 'main'); // (clean: true, unpushed: 2)

  final result = await git.sync(dir, 'main');
  switch (result.outcome) {
    case SyncOutcome.conflict:
      print('Conflicting files: ${result.conflictedFiles}');
      await git.resolve(dir, 'main', ConflictResolution.keepRemote);
    case SyncOutcome.dirtyTree:
      print('Commit first: ${result.conflictedFiles}');
    default:
      print(result.outcome);
  }

  for (final rev in await git.fileHistory(dir, 'today.md')) {
    print('${rev.date} ${rev.author} ${rev.message} (${rev.path})');
    final text = await git.showFile(dir, rev.commit, rev.path);
  }
}
```

SSH with a key file (the public key is derived from the private key, no
`.pub` file is needed):

```dart
GitBackend(
  auth: GitAuth(
    method: AuthMethod.sshKey,
    sshKeyPath: '/path/to/id_ed25519',
    sshPassphrase: 'optional',
  ),
  knownHostsPath: '/path/to/known_hosts.json', // {"host": "SHA256:..."}
);
```

`AuthMethod.sshAgent` uses `SSH_AUTH_SOCK` (or the socket path given as
`sshKeyPath`) on Linux and macOS.

## Development

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test                                # unit, local-remote and git interop tests
dart test --run-skipped -t network       # clones a public repository over HTTPS
dart test --run-skipped -t ssh           # needs sshd and ssh-keygen (openssh-server)
```

Interop tests use the `git` CLI and are skipped when it is not installed.

## Dependencies and licences

Runtime: `crypto` (BSD-3-Clause) and `dartssh2` (MIT) with its dependencies
`pointycastle` (MIT), `asn1lib` (BSD-3-Clause), `pinenacl` (MIT), `convert`,
`meta`, `typed_data`, `collection` (BSD-3-Clause). All are pure Dart and
compatible with F-Droid's requirements. zlib comes from `dart:io`, HTTP from
`dart:io`'s `HttpClient`; a small pure-Dart inflater is included for parsing
received packs.
