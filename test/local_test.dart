import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  final backend =
      GitBackend(authorName: 'Tester', authorEmail: 'tester@example.com');

  test('init, commit all, status, showFile', () async {
    final dir = tempDir();
    expect(await backend.isRepository(dir), isFalse);
    await backend.init(dir, branch: 'notes');
    expect(await backend.isRepository(dir), isTrue);
    expect(
        File('$dir/.git/HEAD').readAsStringSync(), 'ref: refs/heads/notes\n');

    // Nothing to commit on an unborn branch.
    expect(await backend.commit(dir, 'empty'), isFalse);
    expect((await backend.status(dir, 'notes')).clean, isTrue);

    writeFile(dir, 'a.md', '# A\n');
    writeFile(dir, 'dir/b.md', 'b\n');
    writeFile(dir, '.gitmarker/state.json', '{}');
    var st = await backend.status(dir, 'notes');
    expect(st.clean, isFalse);

    expect(await backend.commit(dir, 'first'), isTrue);
    st = await backend.status(dir, 'notes');
    expect(st.clean, isTrue);
    expect(st.unpushed, 1);
    expect(await backend.commit(dir, 'again'), isFalse);

    final hist = await backend.fileHistory(dir, 'a.md');
    expect(hist, hasLength(1));
    expect(hist.single.author, 'Tester');
    expect(hist.single.message, 'first');
    expect(await backend.showFile(dir, hist.single.commit, 'a.md'), '# A\n');
    expect(
        await backend.showFile(
            dir, hist.single.commit.substring(0, 8), 'dir/b.md'),
        'b\n');
    expect(await backend.showFile(dir, 'HEAD', 'missing.md'), isNull);
    expect(await backend.showFile(dir, 'f' * 40, 'a.md'), isNull);
    // .gitmarker/ untracked content is not committed automatically.
    expect(
        await backend.showFile(dir, 'HEAD', '.gitmarker/state.json'), isNull);

    writeFile(dir, 'a.md', '# A\nmore\n');
    File('$dir/dir/b.md').deleteSync();
    expect((await backend.status(dir, 'notes')).clean, isFalse);
    expect(await backend.commit(dir, 'second'), isTrue);
    expect((await backend.status(dir, 'notes')).clean, isTrue);
    expect(await backend.showFile(dir, 'HEAD', 'dir/b.md'), isNull);
    expect(await backend.showFile(dir, 'notes', 'a.md'), '# A\nmore\n');
  });

  test('gitignore is honoured', () async {
    final dir = tempDir();
    await backend.init(dir, branch: 'main');
    writeFile(dir, '.gitignore', '*.tmp\nbuild/\n!keep.tmp\n/root-only.md\n');
    writeFile(dir, 'x.tmp', 'x');
    writeFile(dir, 'keep.tmp', 'k');
    writeFile(dir, 'build/out.md', 'o');
    writeFile(dir, 'root-only.md', 'r');
    writeFile(dir, 'sub/root-only.md', 's');
    writeFile(dir, 'note.md', 'n');
    expect(await backend.commit(dir, 'c'), isTrue);
    expect(await backend.showFile(dir, 'HEAD', 'x.tmp'), isNull);
    expect(await backend.showFile(dir, 'HEAD', 'keep.tmp'), 'k');
    expect(await backend.showFile(dir, 'HEAD', 'build/out.md'), isNull);
    expect(await backend.showFile(dir, 'HEAD', 'root-only.md'), isNull);
    expect(await backend.showFile(dir, 'HEAD', 'sub/root-only.md'), 's');
    expect((await backend.status(dir, 'main')).clean, isTrue);
  });

  test('partial-path commit leaves other changes alone', () async {
    final dir = tempDir();
    await backend.init(dir, branch: 'main');
    writeFile(dir, 'a.md', 'a1');
    writeFile(dir, 'b.md', 'b1');
    writeFile(dir, 'c.md', 'c1');
    await backend.commit(dir, 'base');

    writeFile(dir, 'a.md', 'a2');
    writeFile(dir, 'b.md', 'b2');
    File('$dir/c.md').deleteSync();
    writeFile(dir, 'folder/new.md', 'n');
    expect(
        await backend
            .commit(dir, 'only a and c', paths: ['a.md', 'c.md', 'folder']),
        isTrue);
    expect(await backend.showFile(dir, 'HEAD', 'a.md'), 'a2');
    expect(await backend.showFile(dir, 'HEAD', 'b.md'), 'b1');
    expect(await backend.showFile(dir, 'HEAD', 'c.md'), isNull);
    expect(await backend.showFile(dir, 'HEAD', 'folder/new.md'), 'n');
    expect((await backend.status(dir, 'main')).clean, isFalse);
    // Nothing changed for these paths anymore.
    expect(await backend.commit(dir, 'noop', paths: ['a.md']), isFalse);
    expect(await backend.commit(dir, 'rest', paths: ['b.md']), isTrue);
    expect((await backend.status(dir, 'main')).clean, isTrue);
  });

  test('history follows renames', () async {
    final dir = tempDir();
    await backend.init(dir, branch: 'main');
    writeFile(dir, 'old.md', 'v1\n');
    writeFile(dir, 'other.md', 'o\n');
    await backend.commit(dir, 'create');
    writeFile(dir, 'old.md', 'v2\n');
    await backend.commit(dir, 'edit');
    File('$dir/old.md').renameSync('$dir/mid.md');
    await backend.commit(dir, 'rename 1');
    writeFile(dir, 'other.md', 'o2\n');
    await backend.commit(dir, 'unrelated');
    Directory('$dir/sub').createSync();
    File('$dir/mid.md').renameSync('$dir/sub/new.md');
    await backend.commit(dir, 'rename 2');
    writeFile(dir, 'sub/new.md', 'v3\n');
    await backend.commit(dir, 'edit again');

    final hist = await backend.fileHistory(dir, 'sub/new.md');
    expect(hist.map((r) => r.message),
        ['edit again', 'rename 2', 'rename 1', 'edit', 'create']);
    expect(hist.map((r) => r.path),
        ['sub/new.md', 'sub/new.md', 'mid.md', 'old.md', 'old.md']);
    expect(await backend.showFile(dir, hist[3].commit, hist[3].path), 'v2\n');
    expect(hist.first.date.isAfter(DateTime(2020)), isTrue);
  });

  group('interop with git CLI', skip: skipNoGit, () {
    test('our commits pass fsck and keep git status clean', () async {
      final dir = tempDir();
      await backend.init(dir, branch: 'main');
      writeFile(dir, 'a.md', 'a\n');
      writeFile(dir, 'nested/deep/b.md', 'b\n');
      writeFile(dir, 'a b/ü.md', 'unicode\n');
      writeFile(dir, '.gitmarker/local.json', '{}');
      await backend.commit(dir, 'one');
      writeFile(dir, 'a.md', 'a2\n');
      File('$dir/nested/deep/b.md').renameSync('$dir/nested/b.md');
      await backend.commit(dir, 'two');

      git(['fsck', '--strict', '--no-dangling'], cwd: dir);
      expect(git(['status', '--porcelain', '--untracked-files=no'], cwd: dir),
          isEmpty);
      expect(
          git(['log', '--format=%s|%an <%ae>'], cwd: dir),
          'two|Tester <tester@example.com>\n'
          'one|Tester <tester@example.com>\n');
      expect(
          git(['log', '--follow', '--format=%s', '--', 'nested/b.md'],
              cwd: dir),
          'two\none\n');
      expect(git(['diff', '--stat', 'HEAD'], cwd: dir), isEmpty);
    });

    test('reads repositories written by git (index, packed refs)', () async {
      final dir = tempDir();
      git(['init', '-q', '-b', 'main'], cwd: dir);
      writeFile(dir, 'x.md', 'x\n');
      writeFile(dir, 'y/z.md', 'z\n');
      git(['add', '-A'], cwd: dir);
      git(['commit', '-q', '-m', 'cli'], cwd: dir);
      git(['mv', 'x.md', 'w.md'], cwd: dir);
      git(['commit', '-q', '-m', 'mv'], cwd: dir);
      git(['pack-refs', '--all'], cwd: dir);
      git(['gc', '-q'], cwd: dir);
      expect((await backend.status(dir, 'main')).clean, isTrue);
      writeFile(dir, 'w.md', 'changed\n');
      expect((await backend.status(dir, 'main')).clean, isFalse);
      expect(await backend.commit(dir, 'ours'), isTrue);
      expect(git(['status', '--porcelain'], cwd: dir), isEmpty);
      expect(git(['log', '--follow', '--format=%s', '--', 'w.md'], cwd: dir),
          'ours\nmv\ncli\n');
      final hist = await backend.fileHistory(dir, 'w.md');
      expect(hist.map((h) => h.message), ['ours', 'mv', 'cli']);

      // Staged-elsewhere changes survive a partial commit.
      writeFile(dir, 'y/z.md', 'staged\n');
      git(['add', 'y/z.md'], cwd: dir);
      writeFile(dir, 'w.md', 'mine\n');
      expect(await backend.commit(dir, 'partial', paths: ['w.md']), isTrue);
      expect(git(['status', '--porcelain'], cwd: dir), 'M  y/z.md\n');
      git(['fsck', '--strict', '--no-dangling'], cwd: dir);
    });
  });
}
