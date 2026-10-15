# dartgit status

## Milestones

- [x] 1. Objects (loose, packs + idx v2, deltas), refs, index v2, `init`, `commit`, `status`
- [x] 2. History (`fileHistory` with rename following, `showFile`)
- [x] 3. Local transport (path / `file://`): clone, fetch (+prune), push
- [x] 4. `sync` / rebase / conflict / `resolve`
- [ ] 5. HTTPS smart transport
- [ ] 6. SSH transport (dartssh2)

## Design decisions

- Core is synchronous `dart:io`; `GitBackend` runs each call in `Isolate.run`
  (`useIsolates: false` for debugging).
- zlib: `dart:io` for loose objects and indexed pack reads; a small pure-Dart
  inflater (`lib/src/inflate.dart`) for received packs because it reports how
  many compressed bytes each object used.
- Received packs with fewer than 100 objects are exploded to loose objects
  (like `transfer.unpackLimit`), larger ones are stored as `.pack` + `.idx` v2.
- Index: v2/v3 read, v2 written, extensions dropped (Git rebuilds them).
  dev/ino/uid/gid are not available from Dart and are written as 0, so the
  Git CLI re-hashes such files once; status stays clean.
- `commit(paths: null)` behaves like `git add -A && git commit`, except that
  untracked files under `.gitmarker/` are never added; `.gitignore` and
  `.git/info/exclude` are honoured (common subset of the syntax).
- `commit(paths: [...])`: a path naming a directory replaces everything below it.
- No CRLF conversion, no reflogs, no hooks.
- `fileHistory`: exact-blob renames, falling back to a cheap line-similarity
  (>= 50%) among files deleted in the same commit.
- Local remotes (path, `file://`) are served in-process by the same pack
  generation/indexing code as the network transports. Tests also run every
  remote scenario through the real `git upload-pack`/`git receive-pack`
  (stateful smart protocol, the code path SSH uses).
- Smart protocol v0 only; capabilities used: side-band-64k, ofs-delta,
  report-status, delete-refs. No multi_ack: the client sends up to 32
  first-parent ancestors of each local/tracking tip as `have`s, then `done`.
  No thin packs are requested; pushed packs are undeltified.
- Only branches are fetched (`refs/heads/*` -> `refs/remotes/origin/*`, with
  prune); tags are ignored.
- Push without force must be a fast-forward (checked client side).
  Force push uses force-with-lease: the lease is our `refs/remotes/origin/<b>`;
  `resolve(forcePushLocal)` does not fetch first, so a remote that moved since
  the last sync is refused.
- `sync` when diverged replays local first-parent commits onto origin in
  memory (3-way merge per file, line based, insertions/edits touching the
  same lines conflict); only on success are branch, index and work tree
  updated, so a conflict leaves everything untouched. Merge commits in local
  history are flattened to their first-parent diff. Commits that become
  empty are dropped.
- `sync` on a dirty tree returns `dirtyTree` with the changed paths in
  `conflictedFiles`.
- `resolve(abort)` is a no-op (returns `upToDate`), `resolve(keepRemote)`
  fetches and hard-resets the branch to origin (refuses a dirty tree,
  returns `fastForwarded`), `resolve(forcePushLocal)` returns `pushed`.
- Network timeout is an idle timeout on every connect/read (default 2 min).
