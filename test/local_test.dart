// Local commands checked against the git CLI as the golden reference.
import 'dart:convert';
import 'dart:io';

import 'package:dargit/dargit.dart';
import 'package:test/test.dart';

import 'golden.dart';
import 'helpers.dart';

/// `git add -A && git commit -m` on the CLI side, add + commit on dargit's.
/// Returns whether each side committed (git: exit 0; dargit: an id).
Future<void> commitAll(Twin t, Git dg, String message) async {
  cli(['add', '-A'], t.cliDir);
  final r = runGit(['commit', '-q', '-m', message], t.cliDir);
  await dg.add(t.dgDir, ['.']);
  final id = await dg.commit(t.dgDir, message);
  expect(id != null, r.exitCode == 0,
      reason: 'both commit or neither: $message');
  if (id != null) expect(id, cliRevParse(t.cliDir, 'HEAD'));
}

/// The CLI equivalent of `commit(only: paths)`: `git add -A` for paths on
/// disk, then `git commit --only` for the paths git knows.
Future<String?> commitOnly(
    Twin t, Git dg, String message, List<String> paths) async {
  final onDisk = [
    for (final p in paths)
      if (FileSystemEntity.typeSync('${t.cliDir}/$p', followLinks: false) !=
          FileSystemEntityType.notFound)
        p
  ];
  if (onDisk.isNotEmpty) cli(['add', '-A', '--', ...onDisk], t.cliDir);
  final known = [
    for (final p in paths)
      if (lines(cli(['ls-files', '--', p], t.cliDir)).isNotEmpty ||
          lines(cli(
                  ['ls-tree', '-r', '--name-only', 'HEAD', '--', p], t.cliDir))
              .isNotEmpty)
        p
  ];
  final r = known.isEmpty
      ? null
      : runGit(
          ['commit', '-q', '--only', '-m', message, '--', ...known], t.cliDir);
  final id = await dg.commit(t.dgDir, message, only: paths);
  final committed = r != null && r.exitCode == 0;
  expect(id != null, committed, reason: 'both commit or neither: $message');
  if (id != null) expect(id, cliRevParse(t.cliDir, 'HEAD'));
  return id;
}

void main() {
  for (final fmt in ObjectFormat.values) {
    group('${fmt.name}:', skip: skipNoGit, () {
      final dg = goldenGit();

      test('init matches git init', () async {
        final t = await Twin.init(dg, fmt, branch: 'notes');
        await t.expectSame(dg);
        for (final key in [
          'core.bare',
          'core.repositoryformatversion',
          'extensions.objectformat',
        ]) {
          expect(runGit(['config', '--get', key], t.dgDir).stdout,
              runGit(['config', '--get', key], t.cliDir).stdout,
              reason: key);
        }
        expect(await dg.objectFormat(t.dgDir), fmt);
        expect(await dg.isRepository(t.dgDir), isTrue);
        expect(await dg.isRepository('${t.dgDir}/.git'), isFalse);
        expect(await dg.revParse(t.dgDir, 'HEAD'), isNull);
        expect(await dg.log(t.dgDir), isEmpty);
        // Nothing to commit on an unborn branch, as with git.
        await commitAll(t, dg, 'empty');
        // Re-initialising leaves the repository alone.
        await dg.init(t.dgDir, initialBranch: 'other');
        expect(File('${t.dgDir}/.git/HEAD').readAsStringSync(),
            'ref: refs/heads/notes\n');
      });

      test('commits of many kinds of trees have git\'s object ids', () async {
        final t = await Twin.init(dg, fmt);
        t.write('a.md', '# A\n');
        t.write('dir/b.md', 'b\n');
        t.write('dir/sub/deep/c.md', 'c\n');
        t.write('a b/ü ñ.md', 'unicode and spaces\n');
        t.write('empty', '');
        t.write('crlf.txt', 'one\r\ntwo\r\n');
        t.writeBytes('bin.dat', [0, 1, 2, 255, 0, 10]);
        t.write('a.md.d/x', 'sorts after a.md\n');
        t.write('a-b', 'sorts before a.md\n');
        await commitAll(t, dg, 'first');
        await t.expectSame(dg);

        t.write('a.md', '# A\nmore\n');
        t.delete('dir/b.md');
        t.write('dir/new.md', 'new\n');
        t.chmodExec('dir/sub/deep/c.md');
        t.symlink('link', 'a.md');
        await commitAll(t, dg, 'second\n\nwith a body');
        await t.expectSame(dg);

        // A file becomes a directory and a directory becomes a file.
        t.delete('empty');
        t.write('empty/inside.md', 'now a dir\n');
        t.delete('dir/sub');
        t.write('dir/sub', 'now a file\n');
        t.delete('link');
        t.symlink('link', 'dir/new.md');
        await commitAll(t, dg, 'swap');
        await t.expectSame(dg);

        // Mode change only.
        for (final d in t.dirs) {
          Process.runSync('chmod', ['-x', '$d/dir/sub/deep/c.md']);
        }
        t.delete('dir/sub');
        t.write('dir/sub/deep/c.md', 'c\n');
        await commitAll(t, dg, 'mode');
        await t.expectSame(dg);

        await commitAll(t, dg, 'nothing to commit');
        t.delete('a b');
        t.delete('a.md.d');
        await commitAll(t, dg, 'delete directories');
        await t.expectSame(dg);
      });

      test('commit --only leaves changes staged elsewhere alone', () async {
        final t = await Twin.init(dg, fmt);
        for (final f in ['a', 'b', 'c']) {
          t.write('$f.md', '${f}1\n');
        }
        await commitAll(t, dg, 'base');

        t.write('a.md', 'a2\n');
        t.write('b.md', 'b2\n');
        t.both(['add', 'b.md']); // staged outside dargit
        t.delete('c.md');
        t.write('folder/new.md', 'n\n');
        t.write('folder/deeper/more.md', 'm\n');
        await commitOnly(
            t, dg, 'a, c and folder', ['a.md', 'c.md', 'folder', 'ghost.md']);
        await t.expectSame(dg);
        expect(await commitOnly(t, dg, 'nothing new', ['a.md']), isNull);
        expect(await commitOnly(t, dg, 'only a ghost', ['ghost.md']), isNull);
        await commitOnly(t, dg, 'b', ['b.md']);
        await t.expectSame(dg);

        // A path given as ./x or with a trailing slash means the same.
        t.write('folder/new.md', 'n2\n');
        await commitOnly(t, dg, 'folder again', ['folder']);
        await t.expectSame(dg);
      });

      test('first commit with --only on an unborn branch', () async {
        final t = await Twin.init(dg, fmt);
        t.write('one.md', '1\n');
        t.write('two.md', '2\n');
        await commitOnly(t, dg, 'only one', ['one.md']);
        await t.expectSame(dg);
      });

      test('status matches git status in every state', () async {
        final t = await Twin.init(dg, fmt);
        final d = t.dgDir;
        Future<void> same(String state) async {
          expect(
              [for (final e in await dg.status(d)) '$e'],
              lines(cli([
                'status',
                '--porcelain',
                '--untracked-files=all',
                '--no-renames',
              ], d)),
              reason: state);
        }

        await same('unborn, empty');
        writeFile(d, 'u.md', 'u');
        await same('untracked file');
        cli(['add', 'u.md'], d);
        await same('added');
        writeFile(d, 'u.md', 'u2');
        await same('added then modified');
        File('$d/u.md').deleteSync();
        await same('added then deleted');
        writeFile(d, 'u.md', 'u');
        writeFile(d, 'keep.md', 'k');
        writeFile(d, 'dir/x.md', 'x');
        writeFile(d, 'with space.md', 's');
        writeFile(d, 'quote"d.md', 'q');
        writeFile(d, 'tab\there.md', 't');
        cli(['add', '-A'], d);
        cli(['commit', '-q', '-m', 'c'], d);
        await same('clean');
        writeFile(d, 'keep.md', 'k2');
        await same('modified');
        cli(['add', 'keep.md'], d);
        await same('staged');
        writeFile(d, 'keep.md', 'k3');
        await same('staged and modified');
        cli(['rm', '-q', '--cached', 'u.md'], d);
        await same('removed from index, still on disk');
        File('$d/dir/x.md').deleteSync();
        await same('deleted in worktree');
        cli(['rm', '-q', 'with space.md'], d);
        await same('deleted in index');
        Process.runSync('chmod', ['+x', '$d/keep.md']);
        await same('mode change');
        writeFile(d, 'new dir/a.md', 'a');
        writeFile(d, 'new dir/b/c.md', 'c');
        await same('untracked directories');
        cli(['add', 'new dir/a.md'], d);
        writeFile(d, 'new dir/a.md', 'changed after add');
        await same('added then modified in new dir');
        writeFile(d, 'nested/.git/HEAD', 'not ours');
        await same('nested repository');
      });

      test('gitignore and info/exclude match git', () async {
        final t = await Twin.init(dg, fmt);
        final d = t.dgDir;
        writeFile(
            d,
            '.gitignore',
            [
              '# comment',
              '*.log',
              '!important.log',
              '/build/',
              'doc/**/*.pdf',
              '**/tmp',
              'a?c',
              '[abc].txt',
              '[!x]y.md',
              r'\#literal',
              'only-dir/',
              'sub/*.md',
              'trailing   ',
              r'escaped\ ',
              'deep/**',
              '!deep/keep/',
              '',
            ].join('\n'));
        writeFile(d, 'nested/.gitignore', '*.md\n!keep.md\n/anchored\n');
        writeFile(d, '.git/info/exclude', 'excluded.txt\n');
        final paths = [
          'x.log',
          'important.log',
          'dir/y.log',
          'build/out.o',
          'sub/build/out.o',
          'doc/a.pdf',
          'doc/x/y/z.pdf',
          'docs/a.pdf',
          'tmp/a',
          'a/tmp/b',
          'abc',
          'axc',
          'a/abc',
          'a.txt',
          'd.txt',
          'xy.md',
          'zy.md',
          '#literal',
          'only-dir/f',
          'only-dir2',
          'sub/a.md',
          'sub/deeper/a.md',
          'trailing',
          'escaped ',
          'deep/a',
          'deep/keep/b',
          'nested/a.md',
          'nested/keep.md',
          'nested/sub/b.md',
          'nested/anchored',
          'nested/x/anchored',
          'excluded.txt',
          'dir/excluded.txt',
          'plain.md',
        ];
        for (final p in paths) {
          writeFile(d, p, p);
        }
        File('$d/only-dir2').deleteSync();
        writeFile(d, 'only-dir2', 'a file named like a dir pattern');
        final want =
            lines(cli(['status', '--porcelain', '--untracked-files=all'], d));
        expect([for (final e in await dg.status(d)) '$e'], want);

        // Tracked files stay tracked even when a pattern matches them.
        cli(['add', '-f', 'x.log'], d);
        cli(['commit', '-q', '-m', 'forced'], d);
        writeFile(d, 'x.log', 'changed');
        expect([for (final e in await dg.status(d)) '$e'],
            lines(cli(['status', '--porcelain', '--untracked-files=all'], d)));
        await dg.add(d, ['.']);
        expect(
            lines(cli(['ls-files'], d)),
            lines(cli(
                ['ls-files', '--cached', '--others', '--exclude-standard'],
                d)));
      });

      test('reset --hard matches git reset --hard', () async {
        final t = await Twin.init(dg, fmt);
        t.write('a.md', 'one\n');
        t.write('gone/x.md', 'x\n');
        await commitAll(t, dg, 'one');
        final one = cliRevParse(t.cliDir, 'HEAD')!;
        t.write('a.md', 'two\n');
        t.write('b.md', 'b\n');
        t.delete('gone');
        t.write('gone', 'a file now\n');
        await commitAll(t, dg, 'two');
        // Dirty tree: modified, staged and untracked files.
        t.write('a.md', 'dirty\n');
        t.write('b.md', 'staged\n');
        t.both(['add', 'b.md']);
        t.write('untracked.md', 'u\n');
        cli(['reset', '-q', '--hard', one], t.cliDir);
        await dg.resetHard(t.dgDir, one);
        await t.expectSame(dg);
        expect(readFile(t.dgDir, 'untracked.md'), 'u\n');
        expect(readFile(t.dgDir, 'gone/x.md'), 'x\n');
        expect(cli(['reflog', '--format=%gs'], t.dgDir),
            cli(['reflog', '--format=%gs'], t.cliDir));
        // Back to the newer commit by name.
        cli(['reset', '-q', '--hard', 'HEAD@{1}'], t.cliDir);
        await dg.resetHard(t.dgDir, cliRevParse(t.cliDir, 'HEAD')!);
        await t.expectSame(dg);
        await expectLater(
            dg.resetHard(t.dgDir, 'no-such-rev'), throwsA(isA<GitException>()));
      });

      test('rev-parse and rev-list --count match git', () async {
        final t = await Twin.init(dg, fmt);
        final d = t.dgDir;
        for (var i = 0; i < 5; i++) {
          writeFile(d, 'f$i', '$i');
          await dg.add(d, ['.']);
          await dg.commit(d, 'c$i');
        }
        cli(['branch', 'side', 'HEAD~2'], d);
        cli(['tag', 'light', 'HEAD~1'], d);
        cli(['tag', '-a', '-m', 'annotated', 'annot', 'HEAD~3'], d);
        cli(['tag', '-a', '-m', 'tag of tag', 'nested', 'annot'], d);
        cli(['update-ref', 'refs/remotes/origin/main', 'HEAD~4'], d);
        cli([
          'symbolic-ref',
          'refs/remotes/origin/HEAD',
          'refs/remotes/origin/main'
        ], d);
        cli(['pack-refs', '--all'], d);
        cli(['update-ref', 'refs/heads/loose', 'HEAD'], d);
        final head = cliRevParse(d, 'HEAD')!;
        final tree = cli(['rev-parse', 'HEAD^{tree}'], d).trim();
        for (final rev in [
          'HEAD',
          'main',
          'refs/heads/main',
          'heads/main',
          'side',
          'loose',
          'light',
          'annot',
          'nested',
          'tags/annot',
          'origin/main',
          'origin',
          'remotes/origin/main',
          head,
          head.substring(0, 7),
          head.substring(0, 4),
          head.toUpperCase(),
          tree,
          'nope',
          '0' * fmt.hexLength,
          '',
        ]) {
          expect(await dg.revParse(d, rev), cliRevParse(d, rev),
              reason: 'rev-parse "$rev"');
        }
        for (final (rev, exclude) in [
          ('HEAD', null),
          ('side', null),
          ('HEAD', 'side'),
          ('side', 'HEAD'),
          ('annot', 'origin/main'),
        ]) {
          final want = cli([
            'rev-list',
            '--count',
            rev,
            if (exclude != null) '^$exclude',
          ], d)
              .trim();
          expect('${await dg.revListCount(d, rev, exclude: exclude)}', want,
              reason: 'rev-list $rev ^$exclude');
        }
        await expectLater(
            dg.revListCount(d, 'nope'), throwsA(isA<GitException>()));
      });

      test('log, log --follow and show match git', () async {
        final t = await Twin.init(dg, fmt);
        final d = t.dgDir;
        Future<void> commit(String m) async {
          await dg.add(d, ['.']);
          expect(await dg.commit(d, m), isNotNull);
        }

        final body =
            List.generate(40, (i) => 'line $i of a long note').join('\n');
        writeFile(d, 'old.md', '$body\n');
        writeFile(d, 'other.md', 'o\n');
        await commit('create');
        writeFile(d, 'old.md', '$body\nedit\n');
        await commit('edit');
        File('$d/old.md').renameSync('$d/mid.md');
        await commit('rename exact\n\nbody text');
        writeFile(d, 'other.md', 'o2\n');
        await commit('unrelated');
        Directory('$d/sub').createSync();
        File('$d/mid.md').renameSync('$d/sub/new.md');
        writeFile(d, 'sub/new.md', '$body\nedit\nrenamed with an edit\n');
        await commit('rename with edit');
        writeFile(d, 'sub/new.md', 'rewritten entirely\n');
        await commit('rewrite');
        File('$d/other.md').deleteSync();
        await commit('delete other');
        writeFile(d, 'other.md', 'back\n');
        await commit('recreate other');

        List<(String, String?)> followed(String path) {
          final out = cli([
            'log',
            '--first-parent',
            '--follow',
            '--name-only',
            '--format=%x00%H',
            '--',
            path,
          ], d);
          return [
            for (final rec in out.split('\x00').skip(1))
              (
                rec.trim().split('\n').first,
                rec
                    .trim()
                    .split('\n')
                    .skip(1)
                    .where((l) => l.isNotEmpty)
                    .lastOrNull,
              ),
          ];
        }

        for (final path in ['sub/new.md', 'other.md', 'mid.md', 'old.md']) {
          final want = followed(path);
          final got = await dg.log(d, path: path, follow: true);
          expect([for (final e in got) e.commit], [for (final w in want) w.$1],
              reason: 'log --follow $path');
          // git prints no name for the commit that deletes the path.
          for (var i = 0; i < want.length; i++) {
            if (want[i].$2 != null) {
              expect(got[i].path, want[i].$2, reason: '$path at $i');
            }
          }
          expect(
              [for (final e in await dg.log(d, path: path)) e.commit],
              lines(
                  cli(['log', '--first-parent', '--format=%H', '--', path], d)),
              reason: 'log -- $path');
        }
        final all = await dg.log(d);
        expect([for (final e in all) e.commit],
            lines(cli(['log', '--first-parent', '--format=%H'], d)));
        expect([
          for (final e in all) e.message
        ], [
          for (final h in lines(cli(['log', '--format=%H'], d)))
            cli(['log', '-1', '--format=%B', h], d)
                .replaceAll(RegExp(r'\n+$'), '')
        ]);
        expect([for (final e in all) e.subject],
            lines(cli(['log', '--format=%s'], d)));
        expect({for (final e in all) '${e.authorName} <${e.authorEmail}>'},
            {'$goldenName <$goldenEmail>'});
        expect(all.first.date, goldenClock());
        expect(await dg.log(d, rev: all[2].commit), hasLength(all.length - 2));
        await expectLater(dg.log(d, rev: 'nope'), throwsA(isA<GitException>()));

        // show: every path of every commit, plus misses.
        for (final e in all) {
          for (final p
              in lines(cli(['ls-tree', '-r', '--name-only', e.commit], d))) {
            expect(await dg.show(d, e.commit, p), cliShow(d, e.commit, p),
                reason: 'show ${e.commit}:$p');
          }
          for (final p in ['missing.md', 'sub', 'sub/new.md/x']) {
            expect(await dg.show(d, e.commit, p), cliShow(d, e.commit, p));
          }
        }
        expect(await dg.show(d, 'nope', 'old.md'), isNull);
        expect(utf8.decode((await dg.show(d, 'HEAD', 'other.md'))!), 'back\n');
      });

      test('reflog entries match git', () async {
        final t = await Twin.init(dg, fmt);
        t.write('a.md', 'a');
        await commitAll(t, dg, 'first one');
        t.write('a.md', 'b');
        await commitAll(t, dg, 'second\n\nbody');
        for (final ref in ['HEAD', 'main']) {
          expect(cli(['reflog', 'show', '--format=%H %gs', ref], t.dgDir),
              cli(['reflog', 'show', '--format=%H %gs', ref], t.cliDir));
        }
      });

      test('reads repositories git packed and garbage-collected', () async {
        final t = await Twin.init(dg, fmt);
        final d = t.cliDir;
        for (var i = 0; i < 20; i++) {
          writeFile(d, 'notes/n$i.md', 'note $i\n${'line\n' * i}');
          cli(['add', '-A'], d);
          cli(['commit', '-q', '-m', 'c$i'], d);
        }
        cli(['mv', 'notes/n0.md', 'moved.md'], d);
        cli(['commit', '-q', '-m', 'mv'], d);
        cli(['gc', '-q', '--aggressive'], d);
        cli(['pack-refs', '--all'], d);
        expect(await dg.status(d), isEmpty);
        expect([for (final e in await dg.log(d)) e.commit],
            lines(cli(['log', '--format=%H'], d)));
        expect([
          for (final e in await dg.log(d, path: 'moved.md', follow: true))
            e.commit
        ], lines(cli(['log', '--follow', '--format=%H', '--', 'moved.md'], d)));
        writeFile(d, 'moved.md', 'changed\n');
        expect(await dg.commit(d, 'ours', only: ['moved.md']), isNotNull);
        expect(cli(['status', '--porcelain'], d), isEmpty);
        expectFsck(d);
      });

      test('git reads an index written by dargit and vice versa', () async {
        final t = await Twin.init(dg, fmt);
        final d = t.dgDir;
        writeFile(d, 'a.md', 'a');
        writeFile(d, 'b/c.md', 'c');
        await dg.add(d, ['.']);
        cli(['ls-files', '-s'], d); // git reads the index dargit wrote
        cli(['update-index', '--index-version', '3'], d);
        cli(['update-index', '--skip-worktree', 'a.md'], d);
        // dargit reads v3 extended flags.
        expect([for (final e in await dg.status(d)) '$e'],
            lines(cli(['status', '--porcelain', '--untracked-files=all'], d)));
        // Version 4 (feature.manyFiles) is not supported yet.
        cli(['update-index', '--index-version', '4'], d);
        await expectLater(dg.status(d), throwsA(isA<GitException>()));
      });

      test('identity comes from the repository config', () async {
        final d = tempDir();
        final anon = Git(clock: goldenClock);
        await anon.init(d, objectFormat: fmt);
        writeFile(d, 'a.md', 'a');
        await anon.add(d, ['.']);
        await expectLater(
            anon.commit(d, 'x'),
            throwsA(isA<GitException>()
                .having((e) => e.operation, 'op', 'commit')));
        cli(['config', 'user.name', 'Conf'], d);
        cli(['config', 'user.email', 'conf@x'], d);
        expect(await anon.commit(d, 'x'), isNotNull);
        expect(cli(['log', '--format=%an <%ae> %ad', '--date=raw'], d).trim(),
            'Conf <conf@x> $goldenSeconds +0000');
      });
    });
  }
}
