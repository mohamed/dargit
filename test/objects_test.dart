import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dargit/src/hash.dart';
import 'package:dargit/src/index.dart';
import 'package:dargit/src/inflate.dart';
import 'package:dargit/src/objects.dart';
import 'package:dargit/src/pack.dart';
import 'package:dargit/src/repository.dart';
import 'package:dargit/src/util.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('inflate', () {
    test('matches dart:io zlib and reports consumed length', () {
      final rnd = Random(1);
      for (final size in [0, 1, 100, 5000, 70000, 300000]) {
        // Mix of compressible and random data.
        final data = Uint8List.fromList(List.generate(
            size, (i) => i % 7 == 0 ? rnd.nextInt(256) : (i ~/ 13) % 251));
        for (final level in [0, 1, 6, 9]) {
          final z = ZLibCodec(level: level).encode(data);
          final padded = Uint8List.fromList([9, 9, ...z, 1, 2, 3]);
          final r = zlibInflate(padded, 2);
          expect(r.data, data);
          expect(r.consumed, z.length);
        }
      }
    });
  });

  for (final fmt in ObjectFormat.values) {
    group('objects (${fmt.name})', () {
      test('tree and commit round trip', () {
        final entries = [
          TreeEntry(modeFile, 'b.md', '1' * fmt.hexLength),
          TreeEntry(modeTree, 'a', '2' * fmt.hexLength),
          TreeEntry(modeFile, 'a.md', '3' * fmt.hexLength),
        ];
        final parsed = parseTree(serializeTree(entries), fmt);
        // "a.md" sorts before "a/" because '.' < '/'.
        expect(parsed.map((e) => e.name), ['a.md', 'a', 'b.md']);
        final c = Commit(
          tree: '4' * fmt.hexLength,
          parents: ['5' * fmt.hexLength],
          author: Signature('Ann', 'ann@x', DateTime.utc(2020), 120),
          committer: Signature('Bob', 'bob@x', DateTime.utc(2021), -330),
          message: 'hello\n\nbody\n',
        );
        final back = Commit.parse(c.serialize());
        expect(back.tree, c.tree);
        expect(back.parents, c.parents);
        expect(back.author.format(), c.author.format());
        expect(back.committer.format(), contains('-0530'));
        expect(back.message, c.message);
      });

      test('delta application', () {
        final base = utf8Bytes('hello world, hello git');
        // copy 0..11 ("hello world,"), insert " bye"
        final delta = Uint8List.fromList(
            [base.length, 16, 0x90, 12, 4, ...' bye'.codeUnits]);
        expect(
            String.fromCharCodes(applyDelta(base, delta)), 'hello world, bye');
      });

      test('index round trip', () {
        final idx = GitIndex({
          'b': IndexEntry(
              path: 'b',
              id: '1' * fmt.hexLength,
              mode: 0x81a4,
              size: 3,
              mtimeSec: 9),
          'a/c': IndexEntry(path: 'a/c', id: '2' * fmt.hexLength, mode: 0x81ed),
        });
        final back = GitIndex.parse(idx.serialize(fmt), fmt);
        expect(back.entries.keys.toList(), ['a/c', 'b']);
        expect(back.entries['b']!.mtimeSec, 9);
        expect(back.entries['a/c']!.modeString, '100755');
      });
    });

    group('interop (${fmt.name})', skip: skipNoGit, () {
      late String dir;
      setUp(() {
        dir = tempDir();
        git(['init', '-q', '-b', 'main', '--object-format=${fmt.name}'],
            cwd: dir);
        for (var i = 0; i < 30; i++) {
          writeFile(dir, 'notes/n$i.md', 'note $i\n${'line\n' * i}');
          writeFile(dir, 'big.md',
              List.generate(200 + i, (j) => 'row $j').join('\n'));
          git(['add', '-A'], cwd: dir);
          git(['commit', '-q', '-m', 'c$i'], cwd: dir);
        }
      });

      test('reads packed objects (with deltas) written by git gc', () {
        git(['gc', '-q', '--aggressive'], cwd: dir);
        final repo = Repository.open(dir);
        addTearDown(repo.close);
        expect(repo.odb.packs, isNotEmpty);
        final head = git(['rev-parse', 'HEAD'], cwd: dir).trim();
        expect(repo.headCommit, head);
        final all = git(['rev-list', '--objects', '--all'], cwd: dir)
            .split('\n')
            .where((l) => l.isNotEmpty)
            .map((l) => l.substring(0, fmt.hexLength));
        for (final id in all) {
          final o = repo.odb.read(id);
          expect(hashObject(o.type, o.data, fmt), id);
        }
      });

      test('stores packs from git pack-objects (ofs and ref deltas)', () async {
        for (final refDelta in [false, true]) {
          final ids = git(['rev-list', '--objects', '--all'], cwd: dir);
          final pack = await gitPackObjects(dir, ids, ofsDelta: !refDelta);
          final target = tempDir();
          git(['init', '-q', '--bare', '--object-format=${fmt.name}'],
              cwd: target);
          final repo = Repository.open(target);
          final n =
              storePack(repo.odb, pack, unpackLimit: refDelta ? 100000 : 1);
          repo.close();
          expect(n, greaterThan(60));
          final head = git(['rev-parse', 'HEAD'], cwd: dir).trim();
          git(['update-ref', 'refs/heads/main', head], cwd: target);
          git(['fsck', '--strict', '--no-dangling'], cwd: target);
          if (!refDelta) {
            expect(
                Directory('$target/objects/pack')
                    .listSync()
                    .where((f) => f.path.endsWith('.idx')),
                hasLength(1));
            // Our .idx must be byte-identical to the one git computes.
            final idx = Directory('$target/objects/pack')
                .listSync()
                .firstWhere((f) => f.path.endsWith('.idx'));
            final packPath = idx.path.replaceAll('.idx', '.pack');
            git(['index-pack', '-o', '$target/check.idx', packPath],
                cwd: target);
            expect(File('$target/check.idx').readAsBytesSync(),
                File(idx.path).readAsBytesSync());
          }
        }
      });
    });
  }
}
