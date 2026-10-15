/// A small pure-Dart Git implementation for note-taking apps.
library;

export 'src/backend.dart'
    show
        AuthMethod,
        ConflictResolution,
        GitAuth,
        GitBackend,
        SyncOutcome,
        SyncResult;
export 'src/local_ops.dart' show Revision;
export 'src/util.dart' show GitException;
