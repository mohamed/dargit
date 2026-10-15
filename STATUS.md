# dartgit status

## Milestones

- [x] 1. Objects (loose, packs + idx v2, deltas), refs, index v2, `init`, `commit`, `status`
- [x] 2. History (`fileHistory` with rename following, `showFile`)
- [ ] 3. Local transport (path / `file://`): clone, fetch (+prune), push
- [ ] 4. `sync` / rebase / conflict / `resolve`
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
