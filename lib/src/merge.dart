import 'dart:convert';
import 'dart:typed_data';

import 'objects.dart';

/// Splits text into lines, keeping line terminators.
List<String> splitLines(String text) {
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 10) {
      out.add(text.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) out.add(text.substring(start));
  return out;
}

/// A change: base lines [start, end) replaced by [lines].
class _Hunk {
  _Hunk(this.start, this.end, this.lines, this.side);
  final int start, end;
  final List<String> lines;
  final int side; // 0 = ours, 1 = theirs
}

/// Matching line index pairs between [a] and [b] (Myers' O(ND) algorithm).
/// Returns null if the edit distance exceeds [maxD].
List<(int, int)>? _matches(List<int> a, List<int> b, {int maxD = 4000}) {
  // Trim common prefix and suffix first (cheap and very common).
  var pre = 0;
  while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre &&
      suf < b.length - pre &&
      a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
    suf++;
  }
  final n = a.length - pre - suf, m = b.length - pre - suf;
  final result = <(int, int)>[for (var i = 0; i < pre; i++) (i, i)];
  if (n > 0 && m > 0) {
    final max = n + m;
    final offset = max + 1;
    var v = Int32List(2 * max + 3);
    final trace = <Int32List>[];
    var found = -1;
    for (var d = 0; d <= max && d <= maxD; d++) {
      trace.add(Int32List.fromList(v));
      for (var k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
          x = v[offset + k + 1];
        } else {
          x = v[offset + k - 1] + 1;
        }
        var y = x - k;
        while (x < n && y < m && a[pre + x] == b[pre + y]) {
          x++;
          y++;
        }
        v[offset + k] = x;
        if (x >= n && y >= m) {
          found = d;
          break;
        }
      }
      if (found >= 0) break;
    }
    if (found < 0) return null;
    // Backtrack.
    final mid = <(int, int)>[];
    var x = n, y = m;
    for (var d = found; d > 0; d--) {
      v = trace[d];
      final k = x - y;
      int prevK;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        prevK = k + 1;
      } else {
        prevK = k - 1;
      }
      final prevX = v[offset + prevK];
      final prevY = prevX - prevK;
      while (x > prevX && y > prevY) {
        x--;
        y--;
        mid.add((pre + x, pre + y));
      }
      x = prevX;
      y = prevY;
    }
    result.addAll(mid.reversed);
  }
  for (var i = 0; i < suf; i++) {
    result.add((a.length - suf + i, b.length - suf + i));
  }
  return result;
}

List<_Hunk> _hunks(List<String> base, List<String> other, List<int> bi,
    List<int> oi, int side) {
  final matches = _matches(bi, oi);
  if (matches == null) {
    return [_Hunk(0, base.length, other, side)];
  }
  final out = <_Hunk>[];
  var pb = 0, po = 0;
  for (final (i, j) in [...matches, (base.length, other.length)]) {
    if (i > pb || j > po) out.add(_Hunk(pb, i, other.sublist(po, j), side));
    pb = i + 1;
    po = j + 1;
  }
  return out;
}

bool _overlaps(_Hunk a, int start, int end) =>
    // Like git (xdiff): changes conflict when they overlap or touch, i.e.
    // when no unchanged line separates them.
    a.start <= end && start <= a.end;

/// Three-way line merge. Returns the merged text or null on conflict.
String? merge3Text(String base, String ours, String theirs) {
  if (ours == theirs) return ours;
  if (base == ours) return theirs;
  if (base == theirs) return ours;
  final b = splitLines(base), o = splitLines(ours), t = splitLines(theirs);
  final ids = <String, int>{};
  List<int> intern(List<String> l) =>
      [for (final s in l) ids.putIfAbsent(s, () => ids.length)];
  final bi = intern(b), oi = intern(o), ti = intern(t);
  final hunks = [..._hunks(b, o, bi, oi, 0), ..._hunks(b, t, bi, ti, 1)]
    ..sort((x, y) => x.start != y.start ? x.start - y.start : x.end - y.end);

  final out = StringBuffer();
  var pos = 0;
  var i = 0;
  while (i < hunks.length) {
    // Collect a cluster of mutually overlapping hunks.
    var cStart = hunks[i].start, cEnd = hunks[i].end;
    final cluster = [hunks[i++]];
    while (i < hunks.length && _overlaps(hunks[i], cStart, cEnd)) {
      final h = hunks[i++];
      cluster.add(h);
      if (h.end > cEnd) cEnd = h.end;
      if (h.start < cStart) cStart = h.start;
    }
    for (var k = pos; k < cStart; k++) {
      out.write(b[k]);
    }
    final sides = cluster.map((h) => h.side).toSet();
    String render(int side) {
      final sb = StringBuffer();
      var p = cStart;
      for (final h in cluster.where((h) => h.side == side)) {
        for (var k = p; k < h.start; k++) {
          sb.write(b[k]);
        }
        h.lines.forEach(sb.write);
        p = h.end;
      }
      for (var k = p; k < cEnd; k++) {
        sb.write(b[k]);
      }
      return sb.toString();
    }

    if (sides.length == 1) {
      out.write(render(sides.first));
    } else {
      final mine = render(0), other = render(1);
      if (mine != other) return null;
      out.write(mine);
    }
    pos = cEnd;
  }
  for (var k = pos; k < b.length; k++) {
    out.write(b[k]);
  }
  return out.toString();
}

bool _isBinary(Uint8List d) {
  final n = d.length < 8000 ? d.length : 8000;
  for (var i = 0; i < n; i++) {
    if (d[i] == 0) return true;
  }
  return false;
}

bool _same(TreeEntry? a, TreeEntry? b) =>
    a == null ? b == null : b != null && a.id == b.id && a.mode == b.mode;

/// Result of merging two flat trees against a base.
class TreeMerge {
  TreeMerge(this.tree, this.conflicts);
  final Map<String, TreeEntry> tree;
  final List<String> conflicts;
}

/// Three-way merge of flat trees (`path -> entry`), merging text files line
/// by line. New blobs are written to [odb].
TreeMerge mergeTrees(
  ObjectDatabase odb,
  Map<String, TreeEntry> base,
  Map<String, TreeEntry> ours,
  Map<String, TreeEntry> theirs,
) {
  final out = <String, TreeEntry>{};
  final conflicts = <String>[];
  final paths = {...base.keys, ...ours.keys, ...theirs.keys};
  for (final p in paths) {
    final b = base[p], o = ours[p], t = theirs[p];
    TreeEntry? r;
    if (_same(o, t)) {
      r = o;
    } else if (_same(b, o)) {
      r = t;
    } else if (_same(b, t)) {
      r = o;
    } else if (b != null &&
        o != null &&
        t != null &&
        [b, o, t].every((e) => e.mode == modeFile || e.mode == modeExec)) {
      final bd = odb.read(b.id).data,
          od = odb.read(o.id).data,
          td = odb.read(t.id).data;
      String? merged;
      if (o.id == t.id) {
        merged = utf8.decode(od, allowMalformed: true);
      } else if (!_isBinary(bd) && !_isBinary(od) && !_isBinary(td)) {
        merged = merge3Text(
          utf8.decode(bd, allowMalformed: true),
          utf8.decode(od, allowMalformed: true),
          utf8.decode(td, allowMalformed: true),
        );
      }
      if (merged == null) {
        conflicts.add(p);
        continue;
      }
      final mode = o.mode == b.mode ? t.mode : o.mode;
      r = TreeEntry(mode, p, odb.write(ObjectType.blob, utf8.encode(merged)));
    } else {
      conflicts.add(p);
      continue;
    }
    if (r != null) out[p] = r;
  }
  // A path cannot be both a file and a directory.
  final dirs = <String>{};
  for (final p in out.keys) {
    var i = p.indexOf('/');
    while (i > 0) {
      dirs.add(p.substring(0, i));
      i = p.indexOf('/', i + 1);
    }
  }
  for (final p in out.keys) {
    if (dirs.contains(p)) conflicts.add(p);
  }
  conflicts.sort();
  return TreeMerge(out, conflicts);
}
