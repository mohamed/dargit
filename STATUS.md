# dartgit status

## Milestones

- [x] 1. Objects (loose, packs + idx v2, deltas), refs, index v2, `init`, `commit`, `status`
- [x] 2. History (`log --follow`, `show`)
- [x] 3. Local transport (path / `file://`): clone, fetch (+prune), push
- [x] 4. Rebase (in memory, aborted on conflict), reset --hard
- [x] 5. HTTPS smart transport
- [x] 6. SSH transport (dartssh2)
- [x] 7. Git-shaped API: one `Git` method per git command; application
  policy (sync, conflict resolution, TOFU host keys, `.gitmarker/`) moved
  to GitMarker; reflogs written; BSD-3-Clause licence.
- [x] 8. SHA-256 repositories (`extensions.objectFormat`), next to SHA-1.
- [x] 9. Tests use the git CLI as the golden reference; line coverage
  98.9% (`dart run coverage:test_with_coverage -- --run-skipped -x network`,
  with sshd installed).

## Layout

| File | Concern |
| --- | --- |
| `lib/src/git.dart` | Public `Git` class: maps each command to a module, runs it in an isolate, turns errors into `GitException`. No Git logic. |
| `lib/src/worktree.dart` | `status`, `add`, `commit`, `reset --hard` |
| `lib/src/history.dart` | `rev-parse`, `rev-list`, `log`, `show` |
| `lib/src/rebase.dart`, `merge.dart` | `rebase`; line-based 3-way merge |
| `lib/src/remote.dart` | `clone`, `fetch`, `push`, `remote` config |
| `lib/src/repository.dart` | Opening/initialising, working-tree scan, checkout, ref updates with reflog |
| `objects.dart`, `pack.dart`, `packgen.dart`, `inflate.dart`, `refs.dart`, `index.dart`, `config.dart`, `ignore.dart` | Git file formats |
| `lib/src/transport/` | pkt-line, smart protocol, local/HTTP/SSH channels |
| `lib/src/credentials.dart` | `Credentials`, `HostKeyVerifier` |
| `lib/src/hash.dart` | `ObjectFormat` (SHA-1 / SHA-256): the hash, id sizes and the zero id, in one place |

## Design decisions and known differences from git

- Object format: `Repository` reads `core.repositoryformatversion` and
  `extensions.objectFormat` when it opens a repository and hands the
  `ObjectFormat` to every component that hashes or embeds ids (object
  database, trees, index, packs and `.idx`, refs, protocol). Nothing else
  knows id lengths. Repository format version 1 with other extensions is
  accepted as long as the object format is known; versions above 1 are
  refused. No conversion between formats and no `compatObjectFormat`.

- Core is synchronous `dart:io`; `Git` runs each command in `Isolate.run`
  (`useIsolates: false` for debugging). A `HostKeyVerifier` must therefore
  be sendable (a top-level function or a closure over plain values).
- zlib: `dart:io`, plus a small pure-Dart inflater for received packs (it
  reports how many compressed bytes each object used).
- Received packs with fewer than 100 objects are exploded to loose objects
  (`transfer.unpackLimit`); larger ones are stored as `.pack` + `.idx` v2
  (byte-identical to `git index-pack`'s).
- Index: v2/v3 read, v2 written, extensions dropped (git rebuilds them).
  dev/ino/uid/gid are not available from Dart and are written as 0, so git
  re-hashes such files once; status stays clean.
- `status` lists untracked files individually (`--untracked-files=all`) and
  reports renames as delete + add; paths are quoted like
  `core.quotePath=false`.
- `commit(only:)` also adds new files under the given paths
  (`git add -A -- <paths> && git commit --only -- <paths>`); a pathspec that
  matches nothing is ignored instead of failing.
- `log` always follows first parents (dartgit never creates merges); with
  `follow`, renames are exact blob matches, else the most similar deleted
  file with at least 50% common lines.
- `rebase` replays first-parent commits in memory; on conflict it reports
  the files and leaves branch, index and work tree untouched (what `git
  rebase` + `git rebase --abort` leave). Overlapping or touching edits
  conflict. Commits that become empty are dropped.
- Only `refs/heads/*` are fetched, into `refs/remotes/<remote>/*`; tags are
  not fetched. Only the default refspec is supported.
- Push: fast-forward check and `--force-with-lease` (lease = the
  remote-tracking ref) are done client side; packs are undeltified.
- Smart protocol v0; capabilities side-band-64k, ofs-delta, report-status,
  delete-refs; no multi_ack: up to 32 first-parent ancestors of each tip
  are sent as `have`s, then `done`.
- Identity: `authorName`/`authorEmail`, else `user.name`/`user.email` of the
  repository config (global config is not read).
- SSH user: from the URL, else `$USER`. Host keys: `HostKeyVerifier`
  receives `host` or `[host]:port` and OpenSSH's `SHA256:<base64>`.
- Network timeout is an idle timeout on each connect/read.
- No CRLF conversion, hooks, or macOS Unicode normalisation of file names.
- `rev-parse` takes ids, abbreviations and ref names only (no `~`, `^`,
  `@{}`); push takes branches only (`<src>[:<dst>]`).
- Gitlinks (submodule entries) are kept, checked out as empty
  directories, and staged as the submodule's HEAD; submodules are not
  cloned or updated.
- `lsRemote(url)` (`git ls-remote`): lets an app tell an empty remote
  from a missing branch before `clone`.

## Testing

Golden tests: each scenario runs through the `git` CLI and through
dartgit with the same identity and clock (`Git(clock:)`,
`GIT_AUTHOR_DATE`), so both must produce the same object ids. The
comparison uses git's own view of both repositories (`test/golden.dart`:
HEAD, refs, `ls-files -s`, `status --porcelain`, log, reflog,
`fsck --strict`). Every test runs for SHA-1 and SHA-256.

- `local_test`, `edge_cases_test`: working tree, index, commits, reset,
  history, ignore rules, linked worktrees, gitlinks, locks, odd repos.
- `remote_test`, `http_test`, `ssh_test`: clone/fetch/push/rebase/ls-remote
  next to the same git command, via a path, `file://`, git's own
  `upload-pack`/`receive-pack`, `git http-backend` and a throwaway sshd.
- `protocol_test`: the smart protocol against `git upload-pack` /
  `receive-pack --stateless-rpc` with narrowed capabilities (no symref,
  side-band without 64k, no delete-refs) and scripted bad servers.
- `storage_test`: packs written by git (ofs/ref deltas, 64-bit offsets,
  thin packs), `.idx` byte-identical to `git index-pack`, packed refs,
  config values in both directions.
- `merge_test`: the line merge against `git merge-file` (1000 random cases).
- `-t network`: public HTTPS clone. `-t ssh`: throwaway OpenSSH sshd with
  generated keys and test agents; runs in CI.

Differences the golden tests found and fixed: status order (tracked first,
then untracked), symlinks always rehashed (no lstat in Dart), uppercase hex
in rev-parse, `log --follow` across re-created files, HTTP redirects, the
merge conflict rule (touching hunks conflict, like xdiff), clone/fetch
reflog and config, `clone -b` of an empty remote fails like git, linked
worktrees (`commondir`), gitlinks in status/add, deleting symlinks during
checkout, wildmatch bracket expressions, deleting packed refs in SHA-256
repositories, quoted whitespace and legacy `[section.sub]` in config.

## Known limitations / ideas

- Whole packs are held in memory while indexing.
- rev-list and push negotiation walk the full history (no commit-graph).
