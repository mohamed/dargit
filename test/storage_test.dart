// Object, pack, ref and config storage checked against files written and
// read by the git CLI.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartgit/dartgit.dart';
import 'package:dartgit/src/config.dart';
import 'package:dartgit/src/hash.dart';
import 'package:dartgit/src/objects.dart';
import 'package:dartgit/src/pack.dart';
import 'package:dartgit/src/refs.dart';
import 'package:dartgit/src/util.dart' show GitError, fromHex, writeUint32;
import 'package:test/test.dart';

import 'golden.dart';
import 'helpers.dart';

/// A repository whose history makes git produce deltas.
String deltaRepo(ObjectFormat fmt) {
  final d = gitRepo(fmt);
  final body = List.generate(200, (i) => 'line $i of a long file').join('\n');
  for (var i = 0; i < 6; i++) {
    writeFile(d, 'big.md', '$body\nedit $i\n');
    writeFile(d, 'dir/other.md', '$body\nother $i\n');
    cli(['add', '-A'], d);
    cli(['commit', '-q', '-m', 'edit $i'], d);
  }
  cli(['tag', '-a', '-m', 'annotated', 'v1'], d);
  return d;
}

/// Every object git knows in [d], with its type.
Map<String, String> allObjects(String d) => {
      for (final l in lines(cli([
        'cat-file',
        '--batch-all-objects',
        '--batch-check=%(objectname) %(objecttype)',
      ], d)))
        l.split(' ')[0]: l.split(' ')[1],
    };

/// Reads every object of [d] through dartgit and checks it hashes to its id.
void expectReadsAll(String d, ObjectFormat fmt) {
  final db = ObjectDatabase('$d/.git/objects', fmt);
  final objects = allObjects(d);
  expect(objects, isNotEmpty);
  objects.forEach((id, type) {
    final o = db.read(id);
    expect(o.type.label, type);
    expect(hashObject(o.type, o.data, fmt), id);
  });
  db.close();
}

/// A pack with the git header, [body] and a valid trailer.
Uint8List rawPack(ObjectFormat fmt, int count, List<int> body,
    {int version = 2}) {
  final b = BytesBuilder()..add(ascii.encode('PACK'));
  writeUint32(b, version);
  writeUint32(b, count);
  b.add(body);
  final data = b.takeBytes();
  return Uint8List.fromList([...data, ...fmt.hash(data)]);
}

void main() {
  for (final fmt in ObjectFormat.values) {
    group('${fmt.name}:', skip: skipNoGit, () {
      test('reads packs git writes: ofs-deltas, ref-deltas, large offsets',
          () async {
        final d = deltaRepo(fmt);
        cli(['repack', '-q', '-adf'], d);
        expectReadsAll(d, fmt);
        cli(['-c', 'repack.useDeltaBaseOffset=false', 'repack', '-q', '-adf'],
            d);
        expect(cli(['verify-pack', '-v', ...packIdx(d)], d),
            contains('chain length'));
        expectReadsAll(d, fmt);
        // 64-bit offset table, as for packs over 2 GiB.
        final ids = await cliBytes(['rev-list', '--objects', '--all'], d);
        final name = utf8
            .decode(await cliBytes([
              'pack-objects',
              '-q',
              '--index-version=2,0x40',
              '.git/objects/pack/large',
            ], d, input: ids))
            .trim();
        for (final f in Directory('$d/.git/objects/pack').listSync()) {
          if (!f.path.contains('large-$name')) f.deleteSync();
        }
        expectReadsAll(d, fmt);
        // Abbreviated ids are found in packs.
        final head = cliRevParse(d, 'HEAD')!;
        final dg = goldenGit(useIsolates: false);
        expect(await dg.revParse(d, head.substring(0, 9)), head);
      });

      test('writes the .idx git writes, large offsets included', () async {
        final d = deltaRepo(fmt);
        final ids = await cliBytes(['rev-list', '--objects', '--all'], d);
        final pack =
            await cliBytes(['pack-objects', '-q', '--stdout'], d, input: ids);
        for (final limit in [0x7fffffff, 0x40]) {
          final odb = tempDir('odb');
          final n = storePack(ObjectDatabase(odb, fmt), pack,
              unpackLimit: 1, off32Limit: limit);
          expect(n, allObjects(d).length);
          final packFile = Directory('$odb/pack')
              .listSync()
              .firstWhere((f) => f.path.endsWith('.pack'))
              .path;
          final mine =
              File(packFile.replaceAll('.pack', '.idx')).readAsBytesSync();
          cli([
            'index-pack',
            '--object-format=${fmt.name}',
            '--index-version=2,0x${limit.toRadixString(16)}',
            '-o',
            '$odb/git.idx',
            packFile,
          ], d);
          expect(mine, File('$odb/git.idx').readAsBytesSync(),
              reason: 'limit $limit');
        }
      });

      test('version 1 pack indexes are refused', () async {
        final d = deltaRepo(fmt);
        if (fmt == ObjectFormat.sha256) return; // git has no v1 for SHA-256
        final ids = await cliBytes(['rev-list', '--objects', '--all'], d);
        await cliBytes([
          'pack-objects',
          '-q',
          '--index-version=1',
          '.git/objects/pack/v1'
        ], d, input: ids);
        cli(['prune-packed'], d);
        final db = ObjectDatabase('$d/.git/objects', fmt);
        expect(
            () => db.read(cliRevParse(d, 'HEAD')!),
            throwsA(isA<GitError>()
                .having((e) => e.message, 'message', contains('version 2'))));
      });

      test('thin packs are completed from the local objects', () async {
        final d = deltaRepo(fmt);
        final thin = await cliBytes(
            ['pack-objects', '-q', '--thin', '--stdout', '--revs'], d,
            input: utf8.encode('HEAD\n^HEAD~1\n'));
        // A clone that has HEAD~1 can take it.
        final have = '${tempDir('thin')}/have';
        cli(['branch', 'old', 'HEAD~1'], d);
        cli([
          'clone',
          '-q',
          '--no-local',
          '--single-branch',
          '-b',
          'old',
          d,
          have
        ], d);
        final head = cliRevParse(d, 'HEAD')!;
        expect(cliRevParse(have, head), isNull);
        storePack(ObjectDatabase('$have/.git/objects', fmt), thin);
        expect(cliRevParse(have, head), head);
        expectFsck(have);
        // An empty repository cannot.
        expect(
            () => storePack(ObjectDatabase(tempDir('odb'), fmt), thin),
            throwsA(isA<GitError>().having(
                (e) => e.message, 'message', contains('unresolvable deltas'))));
      });

      test('deltas before their bases, as git index-pack takes them', () async {
        List<int> varint(int v) {
          final out = <int>[];
          do {
            final b = v & 0x7f;
            v >>= 7;
            out.add(v > 0 ? b | 0x80 : b);
          } while (v > 0);
          return out;
        }

        List<int> header(int type, int size) {
          final out = [(type << 4) | (size & 15)];
          size >>= 4;
          while (size > 0) {
            out[out.length - 1] |= 0x80;
            out.add(size & 0x7f);
            size >>= 7;
          }
          return out;
        }

        List<int> refDelta(String baseId, List<int> base, String add) {
          final delta = [
            ...varint(base.length),
            ...varint(base.length + add.length),
            0x90, base.length, // copy all of the base
            add.length, ...utf8.encode(add), // insert
          ];
          return [
            ...header(7, delta.length),
            ...fromHex(baseId),
            ...zlib.encode(delta),
          ];
        }

        final a = utf8.encode('hello world\n');
        final b = [...a, ...utf8.encode('B\n')];
        final aId = hashObject(ObjectType.blob, a, fmt);
        final bId = hashObject(ObjectType.blob, b, fmt);
        final pack = rawPack(fmt, 3, [
          ...refDelta(bId, b, 'C\n'),
          ...refDelta(aId, a, 'B\n'),
          ...header(3, a.length),
          ...zlib.encode(a),
        ]);
        final viaGit = gitRepo(fmt), viaDg = gitRepo(fmt);
        await cliBytes(['index-pack', '--stdin'], viaGit, input: pack);
        storePack(ObjectDatabase('$viaDg/.git/objects', fmt), pack);
        expect(allObjects(viaDg), allObjects(viaGit));
        // An ofs-delta pointing between objects.
        final bad = rawPack(fmt, 2, [
          ...header(3, a.length),
          ...zlib.encode(a),
          ...header(6, 4),
          1, // base one byte back: inside the previous object
          ...zlib.encode([12, 12, 0x90, 12]),
        ]);
        final badFile = '${tempDir('bad')}/bad.pack';
        File(badFile).writeAsBytesSync(bad);
        expect(runGit(['index-pack', badFile], viaGit).exitCode, isNot(0));
        expect(
            () => storePack(ObjectDatabase(tempDir('odb'), fmt), bad),
            throwsA(isA<GitError>().having(
                (e) => e.message, 'message', contains('delta base missing'))));
      });

      test('corrupt packs are rejected', () {
        final db = ObjectDatabase(tempDir('odb'), fmt);
        Matcher error(String text) => throwsA(isA<GitError>()
            .having((e) => e.message, 'message', contains(text)));
        expect(() => storePack(db, Uint8List(10)), error('invalid pack'));
        expect(() => storePack(db, rawPack(fmt, 0, [], version: 4)),
            error('unsupported pack version 4'));
        final good = rawPack(fmt, 0, []);
        good[good.length - 1] ^= 1;
        expect(() => storePack(db, good), error('checksum mismatch'));
        // Object type 5 is reserved.
        expect(() => storePack(db, rawPack(fmt, 1, [0x50, 0x78, 0x9c])),
            error('bad object type 5'));
      });

      test('corrupt objects are reported', () {
        expect(ObjectType.fromCode(4), ObjectType.tag);
        expect(() => ObjectType.fromCode(5), throwsA(isA<GitError>()));
        expect(() => ObjectType.fromLabel('note'), throwsA(isA<GitError>()));
        expect(
            () => parseTree(Uint8List.fromList(utf8.encode('100644 x')), fmt),
            throwsA(isA<GitError>()));
        expect(() => Commit.parse(Uint8List.fromList(utf8.encode('x y\n\nm'))),
            throwsA(isA<GitError>()));
        final db = ObjectDatabase(tempDir('odb'), fmt);
        expect(() => db.read(fmt.zeroId), throwsA(isA<GitError>()));
      });

      test('reads refs packed by git, deletes them like git', () {
        final t = '${tempDir('refs')}/cli';
        final d = deltaRepo(fmt);
        cli(['branch', 'gone'], d);
        cli(['branch', 'kept'], d);
        cli(['tag', '-a', '-m', 'x', 'v2'], d);
        cli(['pack-refs', '--all'], d);
        cli(['clone', '-q', '--mirror', d, t], d);
        final refs = RefStore('$d/.git');
        final want = {
          for (final l in lines(
              cli(['for-each-ref', '--format=%(refname) %(objectname)'], d)))
            l.split(' ')[0]: l.split(' ')[1],
        };
        expect(refs.list('refs/'), want);
        for (final name in ['refs/heads/gone', 'refs/tags/v1']) {
          refs.delete(name);
          cli(['update-ref', '-d', name], t);
        }
        expect(File('$d/.git/packed-refs').readAsStringSync(),
            File('$t/packed-refs').readAsStringSync());
        expect(cli(['show-ref', '-d'], d), cli(['show-ref', '-d'], t));
      });

      test('a ref that cannot be written leaves no lock, as in git', () {
        final d = gitRepo(fmt);
        final head = cliRevParse(d, 'HEAD')!;
        cli(['branch', 'a/b'], d);
        expect(
            runGit(['update-ref', 'refs/heads/a', head], d).exitCode, isNot(0));
        expect(() => RefStore('$d/.git').update('refs/heads/a', head),
            throwsA(isA<FileSystemException>()));
        expect(File('$d/.git/refs/heads/a.lock').existsSync(), isFalse);
      });

      test('an object whose size disagrees with its pack header', () {
        final d = gitRepo(fmt);
        final blob = utf8.encode('hello');
        final id = hashObject(ObjectType.blob, blob, fmt);
        storePack(ObjectDatabase('$d/.git/objects', fmt),
            rawPack(fmt, 1, [0x35, ...zlib.encode(blob)]), // blob, size 5
            unpackLimit: 1);
        final pack = Directory('$d/.git/objects/pack')
            .listSync()
            .whereType<File>()
            .firstWhere((f) => f.path.endsWith('.pack'));
        final bytes = pack.readAsBytesSync();
        bytes[12] = 0x36; // now claims 6 bytes
        pack.writeAsBytesSync(bytes);
        expect(runGit(['cat-file', 'blob', id], d).exitCode, isNot(0));
        expect(
            () => ObjectDatabase('$d/.git/objects', fmt).read(id),
            throwsA(isA<GitError>().having(
                (e) => e.message, 'message', contains('size mismatch'))));
      });

      test('a commit without author reads as git shows it', () {
        final d = gitRepo(fmt);
        final tree = cli(['rev-parse', 'HEAD^{tree}'], d).trim();
        File('$d/c').writeAsStringSync('tree $tree\n\nno author\n');
        final id =
            cli(['hash-object', '-t', 'commit', '-w', '--literally', 'c'], d)
                .trim();
        final c = ObjectDatabase('$d/.git/objects', fmt).readCommit(id);
        expect('${c.author.name}|${c.author.email}|${c.message.trimRight()}',
            cli(['log', '-1', '--format=%an|%ae|%B', id], d).trimRight());
      });

      test('a symbolic ref loop is an error, as in git', () {
        final d = gitRepo(fmt);
        writeFile(d, '.git/refs/heads/a', 'ref: refs/heads/b\n');
        writeFile(d, '.git/refs/heads/b', 'ref: refs/heads/a\n');
        expect(runGit(['rev-parse', 'a'], d).exitCode, isNot(0));
        expect(() => RefStore('$d/.git').resolve('refs/heads/a'),
            throwsA(isA<GitError>()));
      });
    });
  }

  test('delta errors', () {
    final base = Uint8List.fromList([1, 2, 3]);
    Uint8List delta(List<int> ops) =>
        Uint8List.fromList([3, 10, ...ops]); // base 3 bytes, result 10
    // Copy 0x40 bytes from offset 0: beyond the base.
    expect(
        () => applyDelta(base, delta([0x90, 0x40])), throwsA(isA<GitError>()));
    // Insert 5 bytes with only 2 present.
    expect(() => applyDelta(base, delta([5, 1, 2])), throwsA(isA<GitError>()));
    expect(() => applyDelta(base, delta([0])), throwsA(isA<GitError>()));
  });

  group('config agrees with git config', skip: skipNoGit, () {
    test('values git writes are read back', () {
      final d = gitRepo(ObjectFormat.sha1);
      final values = {
        'plain': 'value',
        'spaces': '  padded  ',
        'hash': 'a # not a comment',
        'semi': 'a ; b',
        'quote': 'say "hi"',
        'backslash': r'C:\path\to',
        'tab': 'a\tb',
        'newline': 'a\nb',
        'empty': '',
      };
      values.forEach((k, v) => cli(['config', 'test.$k', v], d));
      cli(['config', 'Sub.Section.key', 'legacy'], d);
      File('$d/.git/config').writeAsStringSync(
          '[legacy.Sub]\n\tkey = old style\n[flag]\n\tbare\n',
          mode: FileMode.append);
      final cfg = GitConfig.load('$d/.git/config');
      values.forEach((k, v) {
        expect(cfg.get('test', null, k), v, reason: k);
      });
      expect(cfg.get('sub', 'Section', 'key'), 'legacy');
      expect(cfg.get('legacy', 'sub', 'key'),
          cli(['config', 'legacy.sub.key'], d).trim());
      expect(cfg.get('flag', null, 'bare'), 'true');
    });

    test('values dartgit writes are read back by git', () {
      final d = gitRepo(ObjectFormat.sha1);
      cli(['config', '--add', 'multi.key', 'one'], d);
      cli(['config', '--add', 'multi.key', 'two'], d);
      final cfg = GitConfig.load('$d/.git/config');
      final values = {
        'plain': 'value',
        'spaces': '  padded  ',
        'hash': 'a # b',
        'quote': 'say "hi"',
        'backslash': r'C:\path',
        'empty': '',
      };
      values.forEach((k, v) => cfg.set('test', 'sub "q"', k, v));
      cfg.set('multi', null, 'key', 'only');
      cfg.save();
      values.forEach((k, v) {
        expect(cli(['config', '--get', 'test.sub "q".$k'], d), '$v\n',
            reason: k);
      });
      expect(cli(['config', '--get-all', 'multi.key'], d), 'only\n');
    });
  });
}

List<String> packIdx(String d) => [
      for (final f in Directory('$d/.git/objects/pack').listSync())
        if (f.path.endsWith('.idx')) f.path,
    ];
