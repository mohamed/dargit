// The line merge checked against `git merge-file` as the golden reference.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartgit/src/hash.dart';
import 'package:dartgit/src/merge.dart';
import 'package:dartgit/src/objects.dart';
import 'package:test/test.dart';

import 'golden.dart';
import 'helpers.dart';

/// `git merge-file -p ours base theirs`: the merged text, or null when git
/// reports conflicts.
String? gitMergeFile(String dir, String base, String ours, String theirs) {
  File('$dir/base').writeAsStringSync(base);
  File('$dir/ours').writeAsStringSync(ours);
  File('$dir/theirs').writeAsStringSync(theirs);
  final r = Process.runSync(
      'git', ['merge-file', '-p', '$dir/ours', '$dir/base', '$dir/theirs'],
      stdoutEncoding: utf8);
  if (r.exitCode < 0 || r.exitCode > 127) fail('git merge-file: ${r.stderr}');
  return r.exitCode == 0 ? r.stdout as String : null;
}

List<String> _edit(Random r, List<String> base, int maxEdits) {
  final l = [...base];
  for (var k = 1 + r.nextInt(maxEdits); k > 0; k--) {
    final i = r.nextInt(l.length + 1);
    switch (r.nextInt(3)) {
      case 0 when i < l.length:
        l[i] = 'changed ${r.nextInt(4)}';
      case 1 when i < l.length:
        l.removeAt(i);
      default:
        l.insert(i, 'inserted ${r.nextInt(4)}');
    }
  }
  return l;
}

String _text(List<String> lines,
    {bool finalNewline = true, String eol = '\n'}) {
  if (lines.isEmpty) return '';
  final s = lines.join(eol);
  return finalNewline ? '$s$eol' : s;
}

void main() {
  group('merge3Text agrees with git merge-file', skip: skipNoGit, () {
    for (final (name, size, edits, seed) in [
      ('short files, few edits', 6, 2, 1),
      ('short files, many edits', 6, 4, 2),
      ('long files', 40, 4, 3),
      ('long files, many edits', 40, 8, 4),
    ]) {
      test(name, () {
        final dir = tempDir('merge');
        final r = Random(seed);
        for (var i = 0; i < 250; i++) {
          final base = List.generate(1 + r.nextInt(size), (j) => 'line $j');
          final finalNewline = r.nextInt(5) != 0;
          final eol = r.nextInt(6) == 0 ? '\r\n' : '\n';
          final b = _text(base, finalNewline: finalNewline, eol: eol);
          final o = _text(_edit(r, base, edits),
              finalNewline: finalNewline, eol: eol);
          final t = _text(_edit(r, base, edits),
              finalNewline: finalNewline, eol: eol);
          expect(merge3Text(b, o, t), gitMergeFile(dir, b, o, t),
              reason: 'case $i\nbase:\n$b\nours:\n$o\ntheirs:\n$t');
        }
      });
    }

    test('edge cases', () {
      final dir = tempDir('merge');
      for (final (b, o, t) in [
        ('', '', ''),
        ('', 'a\n', ''),
        ('', 'a\n', 'b\n'),
        ('', 'a\n', 'a\n'),
        ('a\n', '', 'a\n'),
        ('a\n', '', ''),
        ('a\n', 'b\n', ''),
        ('a', 'a\nb', 'c\na'),
        ('a\nb\nc\n', 'a\nB\nc\n', 'a\nB\nc\n'),
        ('a\nb\nc\nd\n', 'A\nb\nc\nd\n', 'a\nb\nc\nD\n'),
        ('a\nb\n', 'a\nx\nb\n', 'a\ny\nb\n'),
        ('a\nb\nc\n', 'a\nc\n', 'a\nb\nC\n'),
      ]) {
        expect(merge3Text(b, o, t), gitMergeFile(dir, b, o, t),
            reason: 'base ${jsonEncode(b)} ours ${jsonEncode(o)} '
                'theirs ${jsonEncode(t)}');
      }
    });

    test('files too different to diff', () {
      final dir = tempDir('merge');
      String text(String p) =>
          List.generate(2500, (i) => '$p line $i\n').join();
      final b = text('base'), o = text('ours'), t = text('theirs');
      for (final (ours, theirs) in [(o, b), (b, t), (o, t)]) {
        expect(merge3Text(b, ours, theirs), gitMergeFile(dir, b, ours, theirs));
      }
    });
  });

  group('mergeTrees agrees with git merge-tree', skip: skipNoGit, () {
    /// Commits [base], then [ours] and [theirs] on two branches (files as
    /// bytes; a name ending in `*` is executable), and returns git's merged
    /// tree (`ls-tree -r`) next to dartgit's.
    (String, String) both(Map<String, List<int>> base,
        Map<String, List<int>> ours, Map<String, List<int>> theirs) {
      final d = tempDir('mergetree');
      cli(['init', '-q', '-b', 'main'], d);
      void commit(Map<String, List<int>> files, String msg) {
        cli(['rm', '-rq', '--cached', '--ignore-unmatch', '.'], d);
        files.forEach((name, bytes) {
          final exec = name.endsWith('*');
          final path = exec ? name.substring(0, name.length - 1) : name;
          File('$d/$path').writeAsBytesSync(bytes);
          cli(['add', path], d);
          if (exec) cli(['update-index', '--chmod=+x', path], d);
        });
        cli(['commit', '-q', '--allow-empty', '-m', msg], d);
      }

      commit(base, 'base');
      cli(['branch', 'theirs'], d);
      commit(ours, 'ours');
      cli(['checkout', '-qf', 'theirs'], d);
      commit(theirs, 'theirs');
      final tree =
          lines(cli(['merge-tree', '--write-tree', 'main', 'theirs'], d)).first;
      final db = ObjectDatabase('$d/.git/objects');
      Map<String, TreeEntry> flat(String rev) =>
          db.flattenTree(cli(['rev-parse', '$rev^{tree}'], d).trim());
      final m = mergeTrees(db, flat('main~1'), flat('main'), flat('theirs'));
      expect(m.conflicts, isEmpty);
      final mine = [
        for (final MapEntry(:key, :value) in m.tree.entries)
          '${value.mode} blob ${value.id}\t$key',
      ]..sort();
      return (cli(['ls-tree', '-r', tree], d).trimRight(), mine.join('\n'));
    }

    test('text that is not UTF-8 is merged byte for byte', () {
      List<int> latin1(String s) => s.codeUnits;
      final (git, dg) = both(
        {'notes.txt': latin1('caf\xe9\n2\n3\n4\n5\n')},
        {'notes.txt': latin1('caf\xe9 cr\xe8me\n2\n3\n4\n5\n')},
        {'notes.txt': latin1('caf\xe9\n2\n3\n4\nna\xefve\n')},
      );
      expect(dg, git);
    });

    test('the same content with different modes', () {
      final (git, dg) = both(
        {'run.sh': utf8.encode('old\n')},
        {'run.sh*': utf8.encode('new\n')},
        {'run.sh': utf8.encode('new\n')},
      );
      expect(dg, git);
    });
  });

  test('splitLines keeps terminators', () {
    expect(splitLines('x\ny'), ['x\n', 'y']);
    expect(splitLines('x\r\ny\n'), ['x\r\n', 'y\n']);
    expect(splitLines(''), isEmpty);
  });

  group('mergeTrees', () {
    for (final fmt in ObjectFormat.values) {
      test(fmt.name, () {
        final db = ObjectDatabase(tempDir('odb'), fmt);
        TreeEntry blob(String path, String text, [String mode = modeFile]) =>
            TreeEntry(mode, path, db.write(ObjectType.blob, utf8.encode(text)));
        final base = {
          'same': blob('same', 's\n'),
          'ours-only': blob('ours-only', 'o\n'),
          'both': blob('both', '1\n2\n3\n4\n5\n'),
          'conflict': blob('conflict', 'x\n'),
          'deleted-modified': blob('deleted-modified', 'd\n'),
          'binary': blob('binary', 'b\x00\n'),
          'mode': blob('mode', 'm\n'),
          'link': blob('link', 'target', modeLink),
        };
        final ours = {
          ...base,
          'ours-only': blob('ours-only', 'o2\n'),
          'both': blob('both', '1x\n2\n3\n4\n5\n'),
          'conflict': blob('conflict', 'ours\n'),
          'binary': blob('binary', 'o\x00\n'),
          'mode': blob('mode', 'm\n', modeExec),
          'link': blob('link', 'other', modeLink),
          'added-same': blob('added-same', 'same\n'),
          'dir': blob('dir', 'a file\n'),
        }..remove('deleted-modified');
        final theirs = {
          ...base,
          'both': blob('both', '1\n2\n3\n4\n5x\n'),
          'conflict': blob('conflict', 'theirs\n'),
          'deleted-modified': blob('deleted-modified', 'd2\n'),
          'binary': blob('binary', 't\x00\n'),
          'mode': blob('mode', 'm2\n'),
          'link': blob('link', 'third', modeLink),
          'added-same': blob('added-same', 'same\n'),
          'dir/inside': blob('dir/inside', 'a dir\n'),
        };
        final m = mergeTrees(db, base, ours, theirs);
        expect(m.conflicts,
            ['binary', 'conflict', 'deleted-modified', 'dir', 'link']);
        String text(String p) => utf8.decode(db.read(m.tree[p]!.id).data);
        expect(text('both'), '1x\n2\n3\n4\n5x\n');
        expect(text('ours-only'), 'o2\n');
        expect(text('mode'), 'm2\n');
        expect(m.tree['mode']!.mode, modeExec);
        expect(m.tree['added-same']!.id, ours['added-same']!.id);
        expect(m.tree['same']!.id, base['same']!.id);
      });
    }
  });
}
