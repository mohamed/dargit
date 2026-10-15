# dartgit

A small, pure-Dart Git implementation for note-taking apps: no Flutter, no
FFI, no native libraries. It was written to replace libgit2 (git2dart) in
GitMarker, so that the Android build has no prebuilt `.so` files (Google
Play's 16 KB page-size requirement, F-Droid's no-prebuilt-binaries policy).

It implements what a Markdown-notes app needs and nothing more. Repositories
it writes are ordinary Git repositories: the Git CLI can read them, and
`git fsck --strict` and `git status` stay clean.

## Principles

- **Same commands as git.** Every method of `Git` is a git command with
  the same meaning: `init`, `clone`, `remote add/set-url/remove/get-url`,
  `status --porcelain`, `add -A`, `commit [--only]`, `reset --hard`,
  `rebase`, `rev-parse`, `rev-list --count`, `log --first-parent
  [--follow]`, `show rev:path`, `fetch [--prune]`, `push
  [--force-with-lease]`.
- **100% compatible with git.** Objects, packs, index, refs, packed-refs,
  reflogs and config are read and written in git's own formats; tests check
  the results with `git fsck --strict`, `git status`, `git log --follow`
  and `git reflog`, and run every remote scenario through the real
  `git upload-pack`/`receive-pack` and `git http-backend`.
- **No application policy.** What to commit, when to sync, how to resolve
  conflicts and which SSH host keys to trust belong to the app (GitMarker's
  `sync` is built from `status`, `fetch`, `rev-list`, `reset --hard`,
  `rebase` and `push`).

## Commands

| `Git` method | git command |
| --- | --- |
| `init(dir, initialBranch:, bare:)` | `git init [-b <branch>] [--bare]` |
| `isRepository(dir)` | is `dir` the top of a work tree |
| `clone(url, dir, branch:)` | `git clone [-b <branch>] <url> <dir>` |
| `remoteGetUrl` / `remoteAdd` / `remoteSetUrl` / `remoteRemove` | `git remote get-url / add / set-url / remove` |
| `status(dir)` | `git status --porcelain --untracked-files=all` |
| `add(dir, pathspecs)` | `git add -A -- <pathspecs>` |
| `commit(dir, msg)` | `git commit -m <msg>` |
| `commit(dir, msg, only: paths)` | `git commit --only -m <msg> -- <paths>` (new files included) |
| `resetHard(dir, rev)` | `git reset --hard <rev>` |
| `rebase(dir, upstream)` | `git rebase <upstream>`, then `git rebase --abort` on conflict |
| `revParse(dir, rev)` | `git rev-parse --verify --quiet <rev>^{commit}` |
| `revListCount(dir, rev, exclude:)` | `git rev-list --count <rev> ^<exclude>` |
| `log(dir, rev:, path:, follow:)` | `git log --first-parent [--follow] [<rev>] [-- <path>]` |
| `show(dir, rev, path)` | `git show <rev>:<path>` (bytes) |
| `fetch(dir, remote:, prune:)` | `git fetch [--prune] <remote>` |
| `push(dir, branch, forceWithLease:)` | `git push [--force-with-lease] <remote> <branch>` |

Objects: loose objects, packfiles with `.idx` v2 and OFS/REF deltas,
SHA-1. Refs: loose, `packed-refs`, symbolic `HEAD` (unborn branches),
reflogs. Index v2/v3 read, v2 written. `.gitignore` and
`.git/info/exclude` are honoured. Transports (smart protocol v0): local
paths and `file://`, HTTP(S), SSH via [`dartssh2`](https://pub.dev/packages/dartssh2).
Every command runs in a background isolate; network operations fail with a
`GitException` after an idle timeout (2 minutes by default).

## Non-goals

SHA-256 repositories, submodules, LFS, merges (only rebase), tags, hooks,
CRLF conversion, sparse checkout, shallow clones, protocol v2, the dumb
HTTP protocol, and reading global/system git config. See
[STATUS.md](STATUS.md) for the design decisions and known differences.

## Usage

```dart
import 'package:dartgit/dartgit.dart';

final git = Git(
  credentials: const UserPassword('oauth2', 'glpat-...'), // or SshKey(...)
  verifyHostKey: myKnownHosts, // (host, 'SHA256:...') => bool, for SSH
  authorName: 'Ada',
  authorEmail: 'ada@example.com',
);

await git.clone('https://gitlab.com/me/notes.git', dir, branch: 'main');
// ... edit today.md ...
await git.commit(dir, 'Edit today.md', only: ['today.md']);

// A "sync": fetch, then fast-forward, push, or rebase and push.
await git.fetch(dir, prune: true);
final ahead = await git.revListCount(dir, 'main', exclude: 'origin/main');
final behind = await git.revListCount(dir, 'origin/main', exclude: 'main');
if (ahead == 0 && behind > 0) await git.resetHard(dir, 'origin/main');
if (ahead > 0 && behind > 0) {
  final r = await git.rebase(dir, 'origin/main');
  if (!r.ok) print('conflicts: ${r.conflicts}');
}
if (ahead > 0) await git.push(dir, 'main');

for (final e in await git.log(dir, path: 'today.md', follow: true)) {
  print('${e.date} ${e.authorName} ${e.subject} (${e.path})');
}
```

SSH: `SshKey(path, passphrase:)` reads OpenSSH or PEM private keys (no
`.pub` needed); `SshAgent()` uses `SSH_AUTH_SOCK` on Linux and macOS. The
user comes from the URL (`git@host:path`, `ssh://user@host/path`). Without
a `verifyHostKey` callback SSH connections fail like `ssh` with an unknown
host.

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
