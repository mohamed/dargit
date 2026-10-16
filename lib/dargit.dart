/// Git in pure Dart. [Git] has one method per `git` command (init, status,
/// add, commit, log, clone, fetch, push, rebase, ...); repositories stay
/// fully compatible with `git`.
library;

export 'src/credentials.dart';
export 'src/git.dart' show Git;
export 'src/hash.dart' show ObjectFormat;
export 'src/history.dart' show LogEntry;
export 'src/rebase.dart' show RebaseResult;
export 'src/util.dart' show GitException;
export 'src/worktree.dart' show StatusEntry;
