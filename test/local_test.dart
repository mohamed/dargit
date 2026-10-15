import 'dart:convert';
import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  for (final fmt in ObjectFormat.values) {
    group(fmt.name, () {
      final git = Git(authorName: 'Tester', authorEmail: 'tester@example.com');
      Future<String?> show(String dir, String rev, String path) async {
        final b = await git.show(dir, rev, path);
        return b == null ? null : utf8.decode(b);
      }

      Future<List<String>> status(String dir) async =>
          [for (final e in await git.status(dir)) '$e'];

      test('init, status, add, commit, show', () async {
        final dir = tempDir();
        expect(await git.isRepository(dir), isFalse);
        await git.init(dir, objectFormat: fmt, initialBranch: 'notes');
        expect(await git.isRepository(dir), isTrue);
        expect(File('$dir/.git/HEAD').readAsStringSync(),
            'ref: refs/heads/notes\n');
        expect(await git.objectFormat(dir), fmt);
        if (hasGit) {
          expect(git_(['rev-parse', '--show-object-format'], dir).trim(),
              fmt.name);
        }
        expect(await git.revParse(dir, 'HEAD'), isNull);
        expect(await git.log(dir), isEmpty);
        expect(await git.commit(dir, 'empty'), isNull);
        expect(await status(dir), isEmpty);

        writeFile(dir, 'a.md', '# A\n');
        writeFile(dir, 'dir/b.md', 'b\n');
        expect(await status(dir), ['?? a.md', '?? dir/b.md']);
        expect(await git.commit(dir, 'nothing staged'), isNull);
        await git.add(dir, ['.']);
        expect(await status(dir), ['A  a.md', 'A  dir/b.md']);
        final first = await git.commit(dir, 'first');
        expect(first, isNotNull);
        expect(await git.revParse(dir, 'HEAD'), first);
        expect(await git.revParse(dir, 'notes'), first);
        expect(await git.revParse(dir, first!.substring(0, 7)), first);
        expect(await status(dir), isEmpty);

        writeFile(dir, 'a.md', '# A\nmore\n');
        File('$dir/dir/b.md').deleteSync();
        expect(await status(dir), [' M a.md', ' D dir/b.md']);
        await git.add(dir, ['dir']);
        expect(await status(dir), [' M a.md', 'D  dir/b.md']);
        await git.commit(dir, 'second');
        expect(await status(dir), [' M a.md']);
        expect(await show(dir, 'HEAD', 'dir/b.md'), isNull);
        expect(await show(dir, 'HEAD', 'a.md'), '# A\n');
        expect(await show(dir, first, 'dir/b.md'), 'b\n');
        expect(await show(dir, 'f' * 40, 'a.md'), isNull);
        expect(await git.revListCount(dir, 'HEAD'), 2);
        expect(await git.revListCount(dir, 'HEAD', exclude: first), 1);
      });

      test('gitignore is honoured', () async {
        final dir = tempDir();
        await git.init(dir, objectFormat: fmt);
        writeFile(
            dir, '.gitignore', '*.tmp\nbuild/\n!keep.tmp\n/root-only.md\n');
        writeFile(dir, 'x.tmp', 'x');
        writeFile(dir, 'keep.tmp', 'k');
        writeFile(dir, 'build/out.md', 'o');
        writeFile(dir, 'root-only.md', 'r');
        writeFile(dir, 'sub/root-only.md', 's');
        expect(await status(dir),
            ['?? .gitignore', '?? keep.tmp', '?? sub/root-only.md']);
        await git.add(dir, ['.']);
        await git.commit(dir, 'c');
        expect(await status(dir), isEmpty);
        expect(await show(dir, 'HEAD', 'x.tmp'), isNull);
        expect(await show(dir, 'HEAD', 'keep.tmp'), 'k');
      });

      test('commit --only leaves other changes alone', () async {
        final dir = tempDir();
        await git.init(dir, objectFormat: fmt);
        for (final f in ['a', 'b', 'c']) {
          writeFile(dir, '$f.md', '${f}1');
        }
        await git.add(dir, ['.']);
        await git.commit(dir, 'base');

        writeFile(dir, 'a.md', 'a2');
        writeFile(dir, 'b.md', 'b2');
        await git.add(dir, ['b.md']); // staged elsewhere
        File('$dir/c.md').deleteSync();
        writeFile(dir, 'folder/new.md', 'n');
        expect(
            await git.commit(dir, 'a and c',
                only: ['a.md', 'c.md', 'folder', 'ghost.md']),
            isNotNull);
        expect(await show(dir, 'HEAD', 'a.md'), 'a2');
        expect(await show(dir, 'HEAD', 'b.md'), 'b1');
        expect(await show(dir, 'HEAD', 'c.md'), isNull);
        expect(await show(dir, 'HEAD', 'folder/new.md'), 'n');
        expect(await status(dir), ['M  b.md'], reason: 'b.md is still staged');
        expect(await git.commit(dir, 'noop', only: ['a.md']), isNull);
        expect(await git.commit(dir, 'rest'), isNotNull);
        expect(await status(dir), isEmpty);
      });

      test('reset --hard discards tracked changes only', () async {
        final dir = tempDir();
        await git.init(dir, objectFormat: fmt);
        writeFile(dir, 'a.md', 'one');
        await git.add(dir, ['.']);
        final one = await git.commit(dir, 'one');
        writeFile(dir, 'a.md', 'two');
        writeFile(dir, 'b.md', 'b');
        await git.add(dir, ['.']);
        await git.commit(dir, 'two');
        writeFile(dir, 'a.md', 'dirty');
        writeFile(dir, 'untracked.md', 'u');
        await git.resetHard(dir, one!);
        expect(readFile(dir, 'a.md'), 'one');
        expect(File('$dir/b.md').existsSync(), isFalse);
        expect(readFile(dir, 'untracked.md'), 'u');
        expect(await status(dir), ['?? untracked.md']);
        expect(await git.revParse(dir, 'HEAD'), one);
      });

      test('log follows renames along first parents', () async {
        final dir = tempDir();
        await git.init(dir, objectFormat: fmt);
        Future<void> commitAll(String m) async {
          await git.add(dir, ['.']);
          await git.commit(dir, m);
        }

        writeFile(dir, 'old.md', 'v1\n');
        writeFile(dir, 'other.md', 'o\n');
        await commitAll('create');
        writeFile(dir, 'old.md', 'v2\n');
        await commitAll('edit');
        File('$dir/old.md').renameSync('$dir/mid.md');
        await commitAll('rename 1\n\nwith a body');
        writeFile(dir, 'other.md', 'o2\n');
        await commitAll('unrelated');
        Directory('$dir/sub').createSync();
        File('$dir/mid.md').renameSync('$dir/sub/new.md');
        await commitAll('rename 2');
        writeFile(dir, 'sub/new.md', 'v3\n');
        await commitAll('edit again');

        final hist = await git.log(dir, path: 'sub/new.md', follow: true);
        expect(hist.map((r) => r.subject),
            ['edit again', 'rename 2', 'rename 1', 'edit', 'create']);
        expect(hist[2].message, 'rename 1\n\nwith a body');
        expect(hist.map((r) => r.path),
            ['sub/new.md', 'sub/new.md', 'mid.md', 'old.md', 'old.md']);
        expect(hist.first.authorName, 'Tester');
        expect(await show(dir, hist[3].commit, hist[3].path!), 'v2\n');
        final noFollow = await git.log(dir, path: 'sub/new.md');
        expect(noFollow.map((r) => r.subject), ['edit again', 'rename 2']);
        expect((await git.log(dir)).length, 6);
      });

      test('a commit needs an identity', () async {
        final dir = tempDir();
        final anon = Git();
        await anon.init(dir, objectFormat: fmt);
        writeFile(dir, 'a.md', 'a');
        await anon.add(dir, ['.']);
        await expectLater(
            anon.commit(dir, 'x'),
            throwsA(isA<GitException>()
                .having((e) => e.operation, 'op', 'commit')));
        File('$dir/.git/config').writeAsStringSync(
            '[user]\n\tname = Conf\n\temail = conf@x\n',
            mode: FileMode.append);
        expect(await anon.commit(dir, 'x'), isNotNull);
        expect((await anon.log(dir)).single.authorName, 'Conf');
      });

      group('interop with git CLI', skip: skipNoGit, () {
        test('fsck, status, log --follow and reflog agree with git', () async {
          final dir = tempDir();
          await git.init(dir, objectFormat: fmt, initialBranch: 'main');
          writeFile(dir, 'a.md', 'a\n');
          writeFile(dir, 'nested/deep/b.md', 'b\n');
          writeFile(dir, 'a b/ü.md', 'unicode\n');
          await git.add(dir, ['.']);
          await git.commit(dir, 'one');
          writeFile(dir, 'a.md', 'a2\n');
          File('$dir/nested/deep/b.md').renameSync('$dir/nested/b.md');
          await git.commit(dir, 'two', only: ['a.md', 'nested']);

          git_(['fsck', '--strict', '--no-dangling'], dir);
          expect(git_(['status', '--porcelain'], dir), isEmpty);
          expect(git_(['log', '--format=%s|%an <%ae>'], dir),
              'two|Tester <tester@example.com>\none|Tester <tester@example.com>\n');
          expect(
              git_(
                  ['log', '--follow', '--format=%s', '--', 'nested/b.md'], dir),
              'two\none\n');
          expect(git_(['reflog', '--format=%gs'], dir),
              'commit: two\ncommit (initial): one\n');

          // The same working tree states give the same porcelain status.
          writeFile(dir, 'a.md', 'changed\n');
          writeFile(dir, 'new.md', 'n\n');
          File('$dir/a b/ü.md').deleteSync();
          writeFile(dir, 'nested/b.md', 'staged\n');
          git_(['add', 'nested/b.md'], dir);
          writeFile(dir, 'nested/b.md', 'staged and changed\n');
          final ours = [for (final e in await git.status(dir)) '$e'];
          final theirs = git_([
            '-c',
            'core.quotePath=false',
            'status',
            '--porcelain',
            '--untracked-files=all'
          ], dir)
              .trimRight()
              .split('\n');
          expect(ours, theirs);
        });

        test('reads repositories written by git (index, packed refs)',
            () async {
          final dir = tempDir();
          git_(
              ['init', '-q', '-b', 'main', '--object-format=${fmt.name}'], dir);
          writeFile(dir, 'x.md', 'x\n');
          writeFile(dir, 'y/z.md', 'z\n');
          git_(['add', '-A'], dir);
          git_(['commit', '-q', '-m', 'cli'], dir);
          git_(['mv', 'x.md', 'w.md'], dir);
          git_(['commit', '-q', '-m', 'mv'], dir);
          git_(['pack-refs', '--all'], dir);
          git_(['gc', '-q'], dir);
          expect(await git.status(dir), isEmpty);
          writeFile(dir, 'w.md', 'changed\n');
          expect(await git.commit(dir, 'ours', only: ['w.md']), isNotNull);
          expect(git_(['status', '--porcelain'], dir), isEmpty);
          expect(git_(['log', '--follow', '--format=%s', '--', 'w.md'], dir),
              'ours\nmv\ncli\n');
          final hist = await git.log(dir, path: 'w.md', follow: true);
          expect(hist.map((h) => h.subject), ['ours', 'mv', 'cli']);

          writeFile(dir, 'y/z.md', 'staged\n');
          git_(['add', 'y/z.md'], dir);
          writeFile(dir, 'w.md', 'mine\n');
          expect(await git.commit(dir, 'partial', only: ['w.md']), isNotNull);
          expect(git_(['status', '--porcelain'], dir), 'M  y/z.md\n');
          git_(['fsck', '--strict', '--no-dangling'], dir);
        });
      });
    });
  }
}

String git_(List<String> args, String dir) => git(args, cwd: dir);
