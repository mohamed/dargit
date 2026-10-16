# dargit

dargit is Git written in pure Dart. There's no FFI, no native library and
no `git` executable behind it, so it runs anywhere Dart runs with `dart:io`:
Android, iOS, Linux, macOS and Windows.

I wrote it for GitMarker, a Markdown notes app that keeps its notes in a
Git repository. GitMarker used libgit2 through git2dart, which meant
shipping prebuilt `.so` files on Android. That gets in the way of Google
Play's 16 KB page-size requirement and of F-Droid, which doesn't accept
prebuilt binaries. dargit covers what such an app needs and stops there.

The repositories it writes are plain Git repositories. You can open them
with the `git` CLI at any time, and `git fsck --strict` has nothing to say
about them.

## Installation

```sh
dart pub add dargit      # or: flutter pub add dargit
```

The web isn't supported, since dargit needs files, sockets and processes
from `dart:io`.

## Usage

```dart
import 'package:dargit/dargit.dart';

final git = Git(
  credentials: const UserPassword('oauth2', 'glpat-...'), // or SshKey(...)
  verifyHostKey: myKnownHosts, // (host, 'SHA256:...') => bool, for SSH
  authorName: 'Ada',
  authorEmail: 'ada@example.com',
);

await git.clone('https://gitlab.com/me/notes.git', dir, branch: 'main');
// ... edit today.md ...
await git.commit(dir, 'Edit today.md', only: ['today.md']);

// A simple sync: fetch, then fast-forward, or rebase and push.
await git.fetch(dir, prune: true);
final ahead = await git.revListCount(dir, 'main', exclude: 'origin/main');
final behind = await git.revListCount(dir, 'origin/main', exclude: 'main');
if (ahead == 0 && behind > 0) await git.resetHard(dir, 'origin/main');
if (ahead > 0 && behind > 0) {
  final r = await git.rebase(dir, 'origin/main');
  if (!r.ok) print('conflicts: ${r.conflicts}');
}
if (ahead > 0) await git.push(dir, 'HEAD:main');

for (final e in await git.log(dir, path: 'today.md', follow: true)) {
  print('${e.date} ${e.authorName} ${e.subject} (${e.path})');
}
```

Each method of `Git` is a git command and behaves like it. If you know what
`git status --porcelain` or `git push --force-with-lease` does, you know
what the matching method does:

| `Git` method | git command |
| --- | --- |
| `init(dir, initialBranch:, bare:, objectFormat:)` | `git init [-b <branch>] [--bare] [--object-format=sha1\|sha256]` |
| `objectFormat(dir)` | `git rev-parse --show-object-format` |
| `isRepository(dir)` | is `dir` the top of a work tree |
| `clone(url, dir, branch:)` | `git clone [-b <branch>] <url> <dir>` |
| `lsRemote(url)` | `git ls-remote <url>` |
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
| `push(dir, refspec, forceWithLease:)` | `git push [--force-with-lease] <remote> <src>[:<dst>]` |

What to commit, when to sync, how to handle a conflict and which SSH host
keys to trust are left to your app. GitMarker's sync, for instance, is
built from `status`, `fetch`, `rev-list`, `reset --hard`, `rebase` and
`push`, much like the example above.

Every command runs on a background isolate, so the UI thread never
blocks. Errors come back as a `GitException` naming the command. Network
operations give up after an idle timeout, two minutes by default.

### Remotes and credentials

dargit talks to local paths and `file://` URLs, to HTTP(S) servers and to
SSH servers, all with Git's smart protocol (version 0).

For HTTPS, pass `UserPassword` (a token works as the password), or put the
credentials in the URL. They are only sent to the host, port and scheme
they were given for: if the server redirects elsewhere, the credentials
stay behind, as with git.

For SSH, `SshKey(path, passphrase:)` reads OpenSSH or PEM private keys (no
`.pub` file needed), and `SshAgent()` talks to the agent at
`SSH_AUTH_SOCK` on Linux and macOS. The user comes from the URL
(`git@host:path`, `ssh://user@host/path`), or else from `$USER`. Host keys
are checked by the `verifyHostKey` callback you pass in, which receives
`host` (or `[host]:port`) and the key's OpenSSH fingerprint
(`SHA256:...`). Without a callback, every SSH connection is refused, the
way `ssh` refuses a host it doesn't know.

## Git compatibility

dargit reads and writes git's own formats: loose objects, packs with
`.idx` version 2 and both kinds of deltas, loose and packed refs, symbolic
refs, reflogs, the index (versions 2 and 3 are read, version 2 is written)
and config. It honours `.gitignore` and `.git/info/exclude`, linked
worktrees, `core.fileMode` and `core.symlinks`, and keeps submodule
entries.

Both object formats are supported: SHA-1, and SHA-256 (the planned default
for Git 3). A repository has one format, read from its config. `clone`
takes the remote's format, and `fetch` and `push` refuse a remote with the
other one, as git does.

Data from other repositories gets the same checks git applies. A tree
that would write outside the working tree or into `.git` (including the
NTFS and HFS+ look-alikes of `.git`) is refused with "invalid path", and
ref names that `git check-ref-format` rejects are ignored when fetching.

The tests use git itself as the reference. Each scenario runs twice, once
with the `git` CLI and once with dargit, with the same author and the same
clock, so both have to produce identical commits. git then describes both
repositories (refs, index, status, log, reflog) and the descriptions have
to match. Remote tests run against git's own `upload-pack` and
`receive-pack`, `git http-backend` and a real OpenSSH server. Everything
runs in both object formats.

## Design choices

These are the places where dargit deliberately does less than git, or
does it differently:

- It never creates merge commits. `rebase` replays your first-parent
  commits in memory. If any of them conflicts, it reports the files and
  leaves branch, index and working tree exactly as they were, which is
  what `git rebase` followed by `git rebase --abort` would leave.
  Overlapping or touching edits conflict, as in git, and commits that
  become empty are dropped.
- `log` always follows first parents. With `follow`, a rename is an exact
  match of the file's content, or else the most similar deleted file with
  at least half of its lines in common.
- Only branches are fetched, into `refs/remotes/<remote>/`. Tags aren't
  fetched, and only the default refspec is supported. Push sends branches
  only, and does the fast-forward and `--force-with-lease` checks on the
  client (the lease is the remote-tracking branch).
- `commit(only:)` adds new files under the given paths, and quietly
  ignores a path that matches nothing (git would fail).
- `status` lists untracked files one by one and shows a rename as a
  deletion plus an addition. Paths are quoted as with
  `core.quotePath=false`.
- Received packs of fewer than 100 objects are unpacked into loose objects
  (git's `transfer.unpackLimit`). Larger ones are kept as a pack, with an
  `.idx` that is byte for byte what `git index-pack` writes.
- Dart doesn't expose `lstat` or device and inode numbers, so dargit
  re-reads symlinks every time and writes zeros for those index fields.
  git re-hashes such files once and then trusts the index again.
- Only the repository's own config is read, not the global or system
  config. The author comes from `authorName` and `authorEmail`, or else
  from `user.name` and `user.email` in the repository.
- On Windows, `core.fileMode` and `core.symlinks` default to false, as in
  git for Windows, and `init` writes both.
- dargit has no direct way to set the executable bit, so it runs
  `chmod +x`. Where there is no `chmod`, executables are checked out
  without the bit and `status` shows them as modified.

## Known gaps

Things that don't work yet, roughly in the order I'd expect to need them:

- Index version 4, which git writes when `feature.manyFiles` is on.
  dargit refuses such a repository instead of reading it.
- Revision expressions such as `HEAD~1`, `main^` or `@{u}`. `revParse`
  takes ids, unique abbreviations and ref names only.
- Protocol v2, shallow clones and the dumb HTTP protocol.
- Packs are held in memory while they're indexed, and `rev-list` and push
  negotiation walk the whole history (there's no commit-graph). Both are
  fine for notes, and would hurt on a very large repository.
- Not planned: converting between SHA-1 and SHA-256, cloning submodules,
  LFS, hooks, CRLF conversion, sparse checkout, and macOS Unicode
  normalisation of file names.

## Development

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test                              # needs the git CLI
dart test --run-skipped -t ssh         # also needs sshd and ssh-keygen
dart test --run-skipped -t network     # clones a public repository
```

Tests that compare with git are skipped when `git` isn't installed.

`tool/coverage.sh` measures line coverage over three runs and merges
them: the whole suite with an SSH server, `test/environment_test.dart`
as the unprivileged user `nobody` (for unreadable files; this part needs
root and `runuser`), and the same file again with no `chmod` on the
`PATH`. With all three, every line of `lib/` is covered. You can also run
it on GitHub from Actions → Coverage → Run workflow; it isn't part of the
normal CI.

## Releasing

Bump `version` in `pubspec.yaml` and `dargitVersion` in
`lib/src/transport/transport.dart` (it's what dargit reports to servers),
add a section for the new version to `CHANGELOG.md`, commit, then push a
tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The Release workflow checks that the tag, the pubspec, `dargitVersion` and
the changelog agree, runs the checks and the tests, and creates the GitHub
release with the changelog section as notes and the package archive
attached. A tag with a suffix such as `v0.2.0-beta.1` makes a pre-release.
Publishing to pub.dev is a manual `dart pub publish`.

## Licence

BSD 3-Clause, © 2026 Mohamed A. Bamakhrama. See [LICENSE](LICENSE).

dargit depends on `crypto` (BSD-3-Clause) and `dartssh2` (MIT), which
brings in `pointycastle` (MIT), `asn1lib` (BSD-3-Clause), `pinenacl`
(MIT), `convert`, `meta`, `typed_data` and `collection` (BSD-3-Clause).
All of them are pure Dart. zlib and HTTP come from `dart:io`, and a small
inflater of its own lets dargit find where each object ends in a pack.
