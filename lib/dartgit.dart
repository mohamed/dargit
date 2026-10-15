/// A small pure-Dart Git implementation. [Git] mirrors the `git` commands
/// a note-taking app needs; repositories stay fully compatible with `git`.
library;

export 'src/credentials.dart';
export 'src/git.dart' show Git;
export 'src/history.dart' show LogEntry;
export 'src/rebase.dart' show RebaseResult;
export 'src/util.dart' show GitException;
export 'src/worktree.dart' show StatusEntry;
