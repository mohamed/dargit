import 'dart:collection';

import 'objects.dart';
import 'local_ops.dart';

/// Objects needed by a peer that wants [wants] and already has [haves]
/// (and everything reachable from them). Unknown haves are ignored.
List<GitObject> objectsToSend(
    ObjectDatabase odb, Iterable<String> wants, Iterable<String> haves) {
  final known = haves.where(odb.has).toList();
  final common = reachable(odb, known);
  final commits = <String>[];
  final edge = <String>{};
  final seen = <String>{};
  final queue = Queue<String>()..addAll(wants);
  while (queue.isNotEmpty) {
    final c = queue.removeFirst();
    if (common.contains(c)) {
      edge.add(c);
      continue;
    }
    if (!seen.add(c)) continue;
    commits.add(c);
    queue.addAll(odb.readCommit(c).parents);
  }

  // Trees and blobs of boundary commits are assumed present on the peer.
  final excluded = <String>{};
  void markTree(String id) {
    if (!excluded.add(id)) return;
    for (final e in odb.readTree(id)) {
      if (e.isTree) {
        markTree(e.id);
      } else {
        excluded.add(e.id);
      }
    }
  }

  for (final c in edge) {
    markTree(odb.readCommit(c).tree);
  }

  final out = <GitObject>[];
  final added = <String>{};
  void addTree(String id) {
    if (excluded.contains(id) || !added.add(id)) return;
    final o = odb.read(id);
    out.add(o);
    for (final e in parseTree(o.data)) {
      if (e.mode == modeGitlink) continue;
      if (e.isTree) {
        addTree(e.id);
      } else if (!excluded.contains(e.id) && added.add(e.id)) {
        out.add(odb.read(e.id));
      }
    }
  }

  for (final c in commits) {
    final o = odb.read(c);
    out.add(o);
    addTree(Commit.parse(o.data).tree);
  }
  return out;
}
