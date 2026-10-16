import 'dart:io';
import 'dart:typed_data';

import '../hash.dart';
import '../history.dart';
import '../objects.dart';
import '../pack.dart';
import '../packgen.dart';
import '../repository.dart';
import '../util.dart';
import 'transport.dart';

/// A repository on the local file system, served in-process with the same
/// pack generation and indexing code as network transports.
class LocalTransport implements Transport {
  LocalTransport(this.path);
  final String path;

  Repository _open() {
    if (!Directory(path).existsSync()) {
      throw GitError("remote repository '$path' does not exist");
    }
    final r = Repository.tryOpen(path);
    if (r == null) throw GitError("'$path' is not a Git repository");
    return r;
  }

  @override
  Future<UploadSession> openUpload() async => _LocalUpload(_open());

  @override
  Future<ReceiveSession> openReceive() async => _LocalReceive(_open());
}

Map<String, String> _advertised(Repository r) => {
      ...r.refs.list('refs/heads/'),
      ...r.refs.list('refs/tags/'),
    };

class _LocalUpload implements UploadSession {
  _LocalUpload(this._repo) : refs = _advertised(_repo);
  final Repository _repo;

  @override
  final Map<String, String> refs;

  @override
  ObjectFormat get format => _repo.format;

  @override
  String? get head => _repo.refs.symbolicTarget('HEAD');

  @override
  String? get headId => _repo.headCommit;

  @override
  Future<Uint8List> fetchPack(List<String> wants, List<String> haves) async {
    for (final w in wants) {
      if (!_repo.odb.has(w)) throw GitError('remote error: not our ref $w');
    }
    return buildPack(objectsToSend(_repo.odb, wants, haves), _repo.format);
  }

  @override
  Future<void> close() async => _repo.close();
}

class _LocalReceive implements ReceiveSession {
  _LocalReceive(this._repo) : refs = _advertised(_repo);
  final Repository _repo;

  @override
  final Map<String, String> refs;

  @override
  ObjectFormat get format => _repo.format;

  @override
  Future<void> push(List<RefUpdate> updates, Uint8List? pack) async {
    if (pack != null && pack.length >= 12 && readUint32(pack, 8) > 0) {
      storePack(_repo.odb, pack);
    }
    final errors = <String>[];
    for (final u in updates) {
      final current = _repo.refs.resolve(u.name) ?? _repo.format.zeroId;
      if (current != u.oldId) {
        errors.add('${u.name} stale info');
        continue;
      }
      if (!isZeroId(u.newId)) {
        if (!_repo.odb.has(u.newId)) {
          errors.add('${u.name} missing object');
          continue;
        }
        final missing = _missingObject(u.newId);
        if (missing != null) {
          errors.add('${u.name} missing object $missing');
          continue;
        }
      }
    }
    if (errors.isNotEmpty) {
      throw GitError('push rejected: ${errors.join('; ')}');
    }
    for (final u in updates) {
      if (isZeroId(u.newId)) {
        _repo.refs.delete(u.name);
      } else {
        _repo.refs.update(u.name, u.newId);
      }
    }
  }

  /// First object missing below [tip] (stopping at commits already
  /// reachable from the advertised refs), or null when complete.
  String? _missingObject(String tip) {
    final odb = _repo.odb;
    final known = reachable(odb, refs.values);
    final checkedTrees = <String>{};
    String? walkTree(String id) {
      if (!checkedTrees.add(id)) return null;
      if (!odb.has(id)) return id;
      for (final e in odb.readTree(id)) {
        if (e.mode == modeGitlink) continue;
        final m = e.isTree ? walkTree(e.id) : (odb.has(e.id) ? null : e.id);
        if (m != null) return m;
      }
      return null;
    }

    final todo = [tip];
    final seen = <String>{};
    while (todo.isNotEmpty) {
      final c = todo.removeLast();
      if (known.contains(c) || !seen.add(c)) continue;
      if (!odb.has(c)) return c;
      final commit = odb.readCommit(c);
      final m = walkTree(commit.tree);
      if (m != null) return m;
      todo.addAll(commit.parents);
    }
    return null;
  }

  @override
  Future<void> close() async => _repo.close();
}
