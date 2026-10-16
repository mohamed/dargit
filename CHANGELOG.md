# Changelog

## 0.1.0

First release.

- `Git`: one method per git command, with git's semantics: `init`,
  `clone`, `lsRemote`, `remote add/set-url/remove/get-url`,
  `status --porcelain`, `add -A`, `commit [--only]`, `reset --hard`,
  `rebase` (aborted on conflict), `rev-parse`, `rev-list --count`,
  `log --first-parent [--follow]`, `show <rev>:<path>`,
  `fetch [--prune]`, `push [--force-with-lease]`.
- Repositories are git's own format: loose objects, packs with `.idx` v2
  and OFS/REF deltas, loose and packed refs, reflogs, the index (v2 and
  v3 read, v2 written), `.gitignore` and `info/exclude`, linked
  worktrees, submodule entries kept as gitlinks, `core.fileMode` and
  `core.symlinks`.
- SHA-1 and SHA-256 repositories (`extensions.objectFormat`).
- Checks on data from other repositories, as git does them: tree paths
  that would leave the working tree or reach into `.git` (with the NTFS
  and HFS+ look-alikes) are refused, invalid ref names are ignored when
  fetching, and HTTP credentials are not sent to another host on a
  redirect. Config values are escaped so that they cannot add lines.
- Remotes over local paths and `file://`, smart HTTP(S) and SSH (keys,
  passphrases, ssh-agent, host-key verification callback), protocol v0.
- Pure Dart, no native libraries and no `git` executable; runs on
  Android, iOS, Linux, macOS and Windows (not on the web).
- Every command is tested against the git CLI as the reference, in both
  object formats; line coverage is 100% (`tool/coverage.sh`).
