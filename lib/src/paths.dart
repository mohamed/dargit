/// Checks on names that come from other repositories (tree entries, ref
/// names) before they become paths on disk, as git checks them.
library;

// Characters HFS+ ignores when comparing names, so ".g<U+200C>it" is ".git".
final _hfsIgnorable =
    RegExp(r'[\u200c-\u200f\u202a-\u202e\u206a-\u206f\ufeff]', unicode: true);

/// Whether [name] would be the `.git` directory on some file system: any
/// case, NTFS trailing dots and spaces, NTFS short name and stream syntax,
/// HFS+ ignorable characters (git's `is_ntfs_dotgit`/`is_hfs_dotgit`).
bool _isDotGit(String name) {
  var n = name.replaceAll(_hfsIgnorable, '').toLowerCase();
  final colon = n.indexOf(':');
  if (colon >= 0) n = n.substring(0, colon);
  n = n.replaceFirst(RegExp(r'[. ]+$'), '');
  return n == '.git' || n == 'git~1';
}

/// Whether a working-tree [path] from a tree object is safe to check out
/// (git's `verify_path` with `core.protectNTFS` and `core.protectHFS`): no
/// empty, `.` or `..` components and no `.git` look-alike, also across
/// backslashes, which Windows treats as separators (and where, as in git
/// for Windows, a backslash is refused outright).
bool isSafeWorktreePath(String path, {bool windows = false}) {
  if (path.isEmpty || path.contains('\u0000')) return false;
  if (windows && path.contains('\\')) return false;
  for (final c in path.split('/')) {
    if (c.isEmpty || c == '.' || c == '..') return false;
  }
  return !path.split(RegExp(r'[/\\]')).any(_isDotGit);
}

final _badRefChars = RegExp(r'[\x00-\x20\x7f~^:?*\[\\]');

/// `git check-ref-format`: whether [name] (e.g. `refs/heads/main`) is a
/// valid ref name, so it cannot point outside `refs/` once it is a path.
bool isValidRefName(String name) {
  if (name.isEmpty ||
      name == '@' ||
      name.contains('..') ||
      name.contains('@{') ||
      name.endsWith('.') ||
      _badRefChars.hasMatch(name)) {
    return false;
  }
  for (final c in name.split('/')) {
    if (c.isEmpty || c.startsWith('.') || c.endsWith('.lock')) return false;
  }
  return true;
}
