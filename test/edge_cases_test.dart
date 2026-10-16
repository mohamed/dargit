// Repository states created by the git CLI, read and changed by dartgit;
// git's own output is the expected result throughout.
import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:dartgit/src/util.dart' show GitError;
import 'package:test/test.dart';

import 'golden.dart';
import 'helpers.dart';

/// dartgit's status lines must be git's.
Future<void> expectStatusLikeGit(Git dg, String dir, {String? reason}) async {
  expect(
      [for (final e in await dg.status(dir)) '$e'],
      lines(cli(
          ['status', '--porcelain', '--untracked-files=all', '--no-renames'],
          dir)),
      reason: reason);
}

/// A repository with one commit made by git.
String gitRepo(ObjectFormat fmt,
    {Map<String, String> files = const {
      'a.md': 'a\n',
    }}) {
  final d = tempDir('edge');
  cli(['init', '-q', '-b', 'main', '--object-format=${fmt.name}'], d);
  files.forEach((p, c) => writeFile(d, p, c));
  cli(['add', '-A'], d);
  cli(['commit', '-q', '-m', 'base'], d);
  return d;
}

void main() {
  for (final fmt in ObjectFormat.values) {
    group('${fmt.name}:', skip: skipNoGit, () {
      final dg = goldenGit();

      test('a conflicted merge: status and commit agree with git', () async {
        final d = gitRepo(fmt, files: {'c.md': 'base\n', 'ok.md': 'ok\n'});
        cli(['checkout', '-q', '-b', 'side'], d);
        writeFile(d, 'c.md', 'side\n');
        cli(['commit', '-q', '-am', 'side'], d);
        cli(['checkout', '-q', 'main'], d);
        writeFile(d, 'c.md', 'main\n');
        cli(['commit', '-q', '-am', 'main'], d);
        expect(runGit(['merge', 'side'], d).exitCode, isNot(0));
        await expectStatusLikeGit(dg, d, reason: 'unmerged');
        expect(runGit(['commit', '-m', 'x'], d).exitCode, isNot(0));
        await expectLater(
            dg.commit(d, 'x'),
            throwsA(isA<GitException>()
                .having((e) => e.message, 'message', contains('unmerged'))));
        // Resolving the path the dartgit way clears the conflict.
        writeFile(d, 'c.md', 'resolved\n');
        await dg.add(d, ['c.md']);
        await expectStatusLikeGit(dg, d, reason: 'resolved');
        expect(cli(['ls-files', '-s', 'c.md'], d), contains(' 0\tc.md'));
      });

      test('linked worktrees and separate git directories', () async {
        final d = gitRepo(fmt);
        final wt = '${tempDir('wt')}/linked';
        cli(['worktree', 'add', '-q', '-b', 'wt', wt], d);
        expect(await dg.isRepository(wt), isTrue);
        writeFile(wt, 'a.md', 'in the worktree\n');
        await expectStatusLikeGit(dg, wt);
        expect(await dg.commit(wt, 'from worktree', only: ['a.md']),
            cliRevParse(wt, 'HEAD'));
        await expectStatusLikeGit(dg, wt);
        expect(cliRevParse(d, 'wt'), cliRevParse(wt, 'HEAD'));
        // A relative gitdir: line.
        final sep = tempDir('sep');
        cli([
          'init',
          '-q',
          '--separate-git-dir',
          '$sep/store.git',
          '--object-format=${fmt.name}',
          '$sep/work'
        ], sep);
        File('$sep/work/.git').writeAsStringSync('gitdir: ../store.git\n');
        writeFile('$sep/work', 'x.md', 'x');
        await dg.add('$sep/work', ['.']);
        await dg.commit('$sep/work', 'x');
        expect(cli(['log', '--format=%s'], '$sep/work'), 'x\n');
        // A .git file pointing nowhere is not a repository.
        final broken = tempDir('broken');
        File('$broken/.git').writeAsStringSync('gitdir: /nonexistent\n');
        expect(await dg.isRepository(broken), isFalse);
        File('$broken/.git').writeAsStringSync('nonsense\n');
        expect(await dg.isRepository(broken), isFalse);
        await expectLater(dg.status(broken), throwsA(isA<GitException>()));
      });

      test('core.fileMode=false ignores the executable bit like git', () async {
        final d = gitRepo(fmt, files: {'a.sh': 'echo\n', 'b.sh': 'b\n'});
        Process.runSync('chmod', ['+x', '$d/b.sh']);
        cli(['add', 'b.sh'], d);
        cli(['commit', '-q', '-m', 'exec'], d);
        cli(['config', 'core.fileMode', 'false'], d);
        Process.runSync('chmod', ['+x', '$d/a.sh']);
        Process.runSync('chmod', ['-x', '$d/b.sh']);
        await expectStatusLikeGit(dg, d);
        writeFile(d, 'b.sh', 'b2\n');
        await dg.add(d, ['.']);
        await dg.commit(d, 'content only');
        expect(cli(['ls-tree', 'HEAD'], d), contains('100755 blob'));
        await expectStatusLikeGit(dg, d);
      });

      test('submodule entries (gitlinks) are kept and checked out as git does',
          () async {
        final d = gitRepo(fmt);
        final sub = cliRevParse(d, 'HEAD')!;
        cli(['update-index', '--add', '--cacheinfo', '160000,$sub,lib/sub'], d);
        cli(['commit', '-q', '-m', 'gitlink'], d);
        final bare = '${tempDir('glbare')}/r.git';
        cli(['clone', '-q', '--bare', d, bare], d);
        final root = tempDir('glclone');
        cli(['clone', '-q', bare, '$root/cli'], root);
        await dg.clone(bare, '$root/dg');
        await Twin('$root/cli', '$root/dg').expectSame(dg);
        expect(Directory('$root/dg/lib/sub').existsSync(), isTrue);
        writeFile('$root/dg', 'a.md', 'edited\n');
        await dg.add('$root/dg', ['.']);
        await dg.commit('$root/dg', 'edit next to a gitlink');
        expect(cli(['ls-tree', '-r', 'HEAD', 'lib'], '$root/dg'),
            cli(['ls-tree', '-r', 'HEAD~1', 'lib'], '$root/dg'));
        await expectStatusLikeGit(dg, '$root/dg');
      });

      test('commits on a detached HEAD, with reflogs like git', () async {
        final t = await Twin.init(dg, fmt);
        t.write('a.md', 'a\n');
        cli(['add', '-A'], t.cliDir);
        cli(['commit', '-q', '-m', 'one'], t.cliDir);
        await dg.add(t.dgDir, ['.']);
        await dg.commit(t.dgDir, 'one');
        t.both(['checkout', '-q', '--detach']);
        t.write('a.md', 'detached\n');
        cli(['commit', '-q', '-am', 'on detached head'], t.cliDir);
        await dg.commit(t.dgDir, 'on detached head', only: ['a.md']);
        await t.expectSame(dg);
        expect(cli(['reflog', '--format=%gs'], t.dgDir),
            cli(['reflog', '--format=%gs'], t.cliDir));
        // reset --hard on a detached HEAD moves HEAD itself.
        cli(['reset', '-q', '--hard', 'main'], t.cliDir);
        await dg.resetHard(t.dgDir, 'main');
        await t.expectSame(dg);
      });

      test('reset --hard through every kind of change', () async {
        final t = await Twin.init(dg, fmt);
        t.write('keep.md', 'k\n');
        t.write('x', 'x is a file\n');
        t.write('run.sh', 'echo\n');
        t.chmodExec('run.sh');
        t.symlink('link', 'keep.md');
        cli(['add', '-A'], t.cliDir);
        cli(['commit', '-q', '-m', 'one'], t.cliDir);
        await dg.add(t.dgDir, ['.']);
        await dg.commit(t.dgDir, 'one');
        await t.expectSame(dg);
        final one = cliRevParse(t.cliDir, 'HEAD')!;
        t.delete('x');
        t.write('x/inside.md', 'x is a dir\n');
        t.delete('run.sh');
        t.delete('link');
        t.symlink('link', 'x/inside.md');
        cli(['add', '-A'], t.cliDir);
        cli(['commit', '-q', '-m', 'two'], t.cliDir);
        await dg.add(t.dgDir, ['.']);
        await dg.commit(t.dgDir, 'two');
        await t.expectSame(dg);
        final two = cliRevParse(t.cliDir, 'HEAD')!;
        for (final target in [one, two, one]) {
          // Something staged-for-removal and an untracked file in the way.
          t.both(['rm', '-q', '--cached', 'keep.md']);
          cli(['reset', '-q', '--hard', target], t.cliDir);
          await dg.resetHard(t.dgDir, target);
          await t.expectSame(dg, reason: 'reset to $target');
        }
        expect(File('${t.dgDir}/run.sh').statSync().mode & 0x40, isNot(0));
        expect(Link('${t.dgDir}/link').targetSync(), 'keep.md');
      });

      test('a repository with an unknown object format is refused like git',
          () async {
        final d = gitRepo(fmt);
        cli(['config', 'core.repositoryformatversion', '1'], d);
        File('$d/.git/config').writeAsStringSync(
            '[extensions]\n\tobjectformat = sha512\n',
            mode: FileMode.append);
        expect(runGit(['status'], d).exitCode, isNot(0));
        await expectLater(
            dg.status(d),
            throwsA(isA<GitException>().having((e) => e.message, 'message',
                "invalid value for 'extensions.objectformat': 'sha512'")));
        cli(['init', '-q', '${d}2'], d);
        File('${d}2/.git/config')
            .writeAsStringSync('[core]\n\trepositoryformatversion = 2\n');
        expect(runGit(['status'], '${d}2').exitCode, isNot(0));
        await expectLater(dg.status('${d}2'), throwsA(isA<GitException>()));
      });

      test('bare repositories and non-repositories', () async {
        final bare = tempDir('bare');
        await dg.init(bare, bare: true, objectFormat: fmt);
        expect(runGit(['status'], bare).exitCode, isNot(0));
        await expectLater(
            dg.status(bare),
            throwsA(isA<GitException>().having(
                (e) => e.message, 'message', contains('working tree'))));
        expect(await dg.isRepository(bare), isFalse);
        expect(await dg.objectFormat(bare), fmt);
        final plain = tempDir('plain');
        expect(runGit(['log'], plain).exitCode, isNot(0));
        await expectLater(
            dg.log(plain),
            throwsA(isA<GitException>().having((e) => e.message, 'message',
                contains('not a Git repository'))));
        await expectLater(
            dg.init('/proc/no/such/dir'),
            throwsA(isA<GitException>()
                .having((e) => e.operation, 'operation', 'init')));
      });

      test('lock files make dartgit fail where git fails', () async {
        final d = gitRepo(fmt);
        writeFile(d, 'a.md', 'changed\n');
        File('$d/.git/index.lock').writeAsStringSync('');
        expect(runGit(['add', 'a.md'], d).exitCode, isNot(0));
        await expectLater(
            dg.add(d, ['.']),
            throwsA(isA<GitException>()
                .having((e) => e.message, 'message', contains('index.lock'))));
        File('$d/.git/index.lock').deleteSync();
        File('$d/.git/refs/heads/main.lock').writeAsStringSync('');
        expect(runGit(['commit', '-qam', 'x'], d).exitCode, isNot(0));
        await expectLater(
            dg.commit(d, 'x', only: ['a.md']),
            throwsA(isA<GitException>().having(
                (e) => e.message, 'message', contains('cannot lock ref'))));
      });

      test('raw commits git can write: extra headers, no final newline',
          () async {
        final d = gitRepo(fmt);
        final tree = cli(['rev-parse', 'HEAD^{tree}'], d).trim();
        final parent = cliRevParse(d, 'HEAD')!;
        final raw = 'tree $tree\nparent $parent\n'
            'author A U Thor <a@x> 1700000000 +0130\n'
            'committer C O Mitter <c@x> 1700000001 -0700\n'
            'encoding UTF-8\n'
            'gpgsig -----BEGIN PGP SIGNATURE-----\n'
            ' \n'
            ' fake\n'
            ' -----END PGP SIGNATURE-----\n'
            '\n'
            'subject without final newline';
        File('$d/raw').writeAsStringSync(raw);
        final id = cli(['hash-object', '-t', 'commit', '-w', 'raw'], d).trim();
        File('$d/raw').deleteSync();
        cli(['update-ref', 'refs/heads/main', id], d);
        final e = (await dg.log(d)).first;
        expect(e.commit, id);
        expect(e.message, cli(['log', '-1', '--format=%B', id], d).trimRight());
        expect(e.authorName, 'A U Thor');
        expect(e.date,
            DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
        expect('$e', contains(id));
        // dartgit keeps extra headers when it only reads the commit.
        expect(await dg.revParse(d, 'HEAD'), id);
        expectFsck(d);
      });

      test('commits without a clock get the current time', () async {
        final d = tempDir('now');
        final g = Git(authorName: 'n', authorEmail: 'n@x');
        await g.init(d, objectFormat: fmt);
        writeFile(d, 'a', 'a');
        await g.add(d, ['.']);
        final before = DateTime.now().subtract(const Duration(seconds: 2));
        await g.commit(d, 'now');
        final e = (await g.log(d)).single;
        expect(e.date.isAfter(before), isTrue);
        expect(cli(['log', '--format=%at', '-1'], d).trim(),
            '${e.date.millisecondsSinceEpoch ~/ 1000}');
      });

      test('pathspecs are normalised like git normalises them', () async {
        final t = await Twin.init(dg, fmt);
        t.write('dir/a.md', '1\n');
        t.write('b.md', '1\n');
        cli(['add', '-A'], t.cliDir);
        cli(['commit', '-q', '-m', 'base'], t.cliDir);
        await dg.add(t.dgDir, ['.']);
        await dg.commit(t.dgDir, 'base');
        t.write('dir/a.md', '2\n');
        t.write('b.md', '2\n');
        cli(['commit', '-q', '--only', '-m', 'spec', '--', './dir/', 'b.md'],
            t.cliDir);
        await dg.commit(t.dgDir, 'spec', only: ['./dir/', '/b.md']);
        await t.expectSame(dg);
        t.write('dir/a.md', '3\n');
        cli(['add', '--', './dir'], t.cliDir);
        await dg.add(t.dgDir, [r'dir\']);
        await t.expectSame(dg);
      });

      test('file names that need quoting in porcelain status', () async {
        final d = gitRepo(fmt);
        for (final name in [
          'ctrl\u0001char',
          'back\\slash',
          'new\nline',
          'del\u007f',
          'naïve',
        ]) {
          writeFile(d, name, name);
        }
        await expectStatusLikeGit(dg, d);
      });

      test('unusual ignore patterns', () async {
        final d = gitRepo(fmt);
        writeFile(
            d,
            '.gitignore',
            [
              'a[b',
              '[z-a]',
              r'\!bang',
              '!',
              '/',
              r'\',
              '[!a]x',
              '[]]y',
              '[a-]z',
              '[[:digit:]]d',
              r'[\]]e',
              'f[[:bogus:]]',
              '*.[ch]',
              'g[^0-9]',
              'h[[:upper:][:punct:]]',
              r'i[a-\z]',
              'j[',
              'k[!]]',
              'dir[/]x',
            ].join('\n'));
        for (final p in [
          'a[b',
          'ab',
          '!bang',
          'z',
          'plain',
          'bx',
          'ax',
          ']y',
          '-z',
          'az',
          'bz',
          '5d',
          'xd',
          ']e',
          'fb',
          'main.c',
          'main.h',
          'main.o',
          'g1',
          'gx',
          'hA',
          'h!',
          'ha',
          'ib',
          'iz',
          'j[',
          'k]',
          'kk',
          'dir/x',
        ]) {
          writeFile(d, p, p);
        }
        await expectStatusLikeGit(dg, d);
      });

      test('rebase refuses what git rebase refuses', () async {
        final d = gitRepo(fmt);
        cli(['branch', 'up'], d);
        expect(runGit(['rebase', 'nope'], d).exitCode, isNot(0));
        await expectLater(dg.rebase(d, 'nope'), throwsA(isA<GitException>()));
        writeFile(d, 'a.md', 'dirty\n');
        expect(runGit(['rebase', 'up'], d).exitCode, isNot(0));
        await expectLater(
            dg.rebase(d, 'up'),
            throwsA(isA<GitException>().having(
                (e) => e.message, 'message', contains('cannot rebase'))));
        final unborn = tempDir('unborn');
        cli(['init', '-q', '--object-format=${fmt.name}', unborn], unborn);
        await expectLater(
            dg.rebase(unborn, 'HEAD'), throwsA(isA<GitException>()));
      });

      test('rebasing an unrelated history replays its root commit like git',
          () async {
        final t = await Twin.init(dg, fmt);
        t.write('main.md', 'm\n');
        cli(['add', '-A'], t.cliDir);
        cli(['commit', '-q', '-m', 'main root'], t.cliDir);
        await dg.add(t.dgDir, ['.']);
        await dg.commit(t.dgDir, 'main root');
        t.both(['checkout', '-q', '--orphan', 'other']);
        t.both(['rm', '-q', '-rf', '--cached', '.']);
        t.delete('main.md');
        t.write('other.md', 'o\n');
        cli(['add', '-A'], t.cliDir);
        cli(['commit', '-q', '-m', 'other root'], t.cliDir);
        await dg.add(t.dgDir, ['.']);
        await dg.commit(t.dgDir, 'other root');
        await t.expectSame(dg);
        cli(['rebase', '-q', 'main'], t.cliDir);
        final r = await dg.rebase(t.dgDir, 'main');
        expect(r.ok, isTrue);
        expect('$r', contains(r.head!));
        await t.expectSame(dg);
        // Already up to date: nothing to replay.
        expect((await dg.rebase(t.dgDir, 'main')).head, r.head);
      });
    });
  }

  test('error and value types', () {
    expect('${GitException('op', 'msg')}', 'GitException(op): msg');
    expect('${GitError('msg')}', 'msg');
    final a = StatusEntry('x', ' ', 'M');
    expect(a, StatusEntry('x', ' ', 'M'));
    expect(a.hashCode, StatusEntry('x', ' ', 'M').hashCode);
    expect(a == StatusEntry('x', 'M', ' '), isFalse);
    expect('$a', ' M x');
  });
}
