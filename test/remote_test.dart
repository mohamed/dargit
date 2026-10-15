import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:dartgit/src/repository.dart';
import 'package:dartgit/src/transport/process.dart';
import 'package:dartgit/src/transport/transport.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// How tests reach the bare "server" repository.
enum Via { path, fileUrl, gitCli }

String bareRepo({String? branch}) {
  final dir = tempDir('remote');
  Repository.init(dir, branch: branch ?? 'main', bare: true).close();
  return dir;
}

void main() {
  for (final via in Via.values) {
    group('via ${via.name}', skip: via == Via.gitCli ? skipNoGit : null, () {
      late GitBackend alice, bob;
      setUp(() {
        if (via == Via.gitCli) {
          debugTransportFactory = (url, o) => ProcessTransport(url);
          addTearDown(() => debugTransportFactory = null);
        }
        alice = GitBackend(
            authorName: 'Alice',
            authorEmail: 'a@x',
            useIsolates: via != Via.gitCli);
        bob = GitBackend(
            authorName: 'Bob',
            authorEmail: 'b@x',
            useIsolates: via != Via.gitCli);
      });
      String url(String path) =>
          via == Via.fileUrl ? Uri.file(path).toString() : path;

      /// A remote with one commit on main, cloned as alice and bob.
      Future<(String remote, String a, String b)> setupPair() async {
        final remote = bareRepo();
        final a = '${tempDir()}/a', b = '${tempDir()}/b';
        await alice.clone(url(remote), a, branch: 'main');
        writeFile(a, 'shared.md', 'line 1\nline 2\nline 3\nline 4\nline 5\n');
        writeFile(a, 'a.md', 'a\n');
        expect(await alice.commit(a, 'initial'), isTrue);
        expect((await alice.sync(a, 'main')).outcome, SyncOutcome.pushed);
        await bob.clone(url(remote), b, branch: 'main');
        expect(readFile(b, 'shared.md'), startsWith('line 1'));
        return (remote, a, b);
      }

      test('empty remote, first push, status and remote url', () async {
        final remote = bareRepo();
        final dir = '${tempDir()}/clone';
        await alice.clone(url(remote), dir, branch: 'main');
        expect(await alice.remoteUrl(dir), url(remote));
        expect(File('$dir/.git/HEAD').readAsStringSync(),
            'ref: refs/heads/main\n');
        expect((await alice.sync(dir, 'main')).outcome, SyncOutcome.upToDate);
        writeFile(dir, 'n.md', 'n\n');
        await alice.commit(dir, 'first');
        expect(await alice.status(dir, 'main'), (clean: true, unpushed: 1));
        expect((await alice.sync(dir, 'main')).outcome, SyncOutcome.pushed);
        expect(await alice.status(dir, 'main'), (clean: true, unpushed: 0));
        expect((await alice.sync(dir, 'main')).outcome, SyncOutcome.upToDate);
        if (hasGit) git(['fsck', '--strict', '--no-dangling'], cwd: remote);
      });

      test('clone of a missing branch fails and removes the directory',
          () async {
        final (remote, _, _) = await setupPair();
        final dir = '${tempDir()}/x';
        await expectLater(
          bob.clone(url(remote), dir, branch: 'notes'),
          throwsA(isA<GitException>()
              .having((e) => e.operation, 'operation', 'clone')
              .having(
                  (e) => e.message, 'message', contains("no branch 'notes'"))),
        );
        expect(Directory(dir).existsSync(), isFalse);
      });

      test('fast-forward, push, prune', () async {
        final (remote, a, b) = await setupPair();
        writeFile(a, 'a.md', 'a2\n');
        writeFile(a, 'new/n.md', 'n\n');
        await alice.commit(a, 'second');
        expect((await alice.sync(a, 'main')).outcome, SyncOutcome.pushed);
        expect(await bob.status(b, 'main'), (clean: true, unpushed: 0));
        expect((await bob.sync(b, 'main')).outcome, SyncOutcome.fastForwarded);
        expect(readFile(b, 'a.md'), 'a2\n');
        expect(readFile(b, 'new/n.md'), 'n\n');
        expect(await bob.status(b, 'main'), (clean: true, unpushed: 0));
        if (hasGit) {
          expect(git(['status', '--porcelain'], cwd: b), isEmpty);
          // Prune: a branch deleted on the remote disappears locally.
          git(['branch', 'tmp', 'main'], cwd: remote);
          await bob.sync(b, 'main');
          expect(File('$b/.git/refs/remotes/origin/tmp').existsSync(), isTrue);
          git(['branch', '-D', 'tmp'], cwd: remote);
          await bob.sync(b, 'main');
          expect(File('$b/.git/refs/remotes/origin/tmp').existsSync(), isFalse);
        }
      });

      test('diverged histories are rebased and pushed', () async {
        final (remote, a, b) = await setupPair();
        writeFile(
            a, 'shared.md', 'line 1 (alice)\nline 2\nline 3\nline 4\nline 5\n');
        await alice.commit(a, 'alice edits top');
        writeFile(a, 'alice.md', 'from alice\n');
        await alice.commit(a, 'alice adds file');
        expect((await alice.sync(a, 'main')).outcome, SyncOutcome.pushed);

        writeFile(
            b, 'shared.md', 'line 1\nline 2\nline 3\nline 4\nline 5 (bob)\n');
        await bob.commit(b, 'bob edits bottom');
        writeFile(b, 'bob.md', 'from bob\n');
        await bob.commit(b, 'bob adds file');
        expect(await bob.status(b, 'main'), (clean: true, unpushed: 2));
        final r = await bob.sync(b, 'main');
        expect(r.outcome, SyncOutcome.rebased, reason: '$r');
        expect(readFile(b, 'shared.md'),
            'line 1 (alice)\nline 2\nline 3\nline 4\nline 5 (bob)\n');
        expect(readFile(b, 'alice.md'), 'from alice\n');
        expect(await bob.status(b, 'main'), (clean: true, unpushed: 0));

        expect(
            (await alice.sync(a, 'main')).outcome, SyncOutcome.fastForwarded);
        expect(readFile(a, 'bob.md'), 'from bob\n');
        expect(readFile(a, 'shared.md'), readFile(b, 'shared.md'));
        final hist = await alice.fileHistory(a, 'shared.md');
        expect(hist.map((h) => h.message),
            ['bob edits bottom', 'alice edits top', 'initial']);
        expect(hist.first.author, 'Bob');
        if (hasGit) {
          git(['fsck', '--strict', '--no-dangling'], cwd: remote);
          expect(
              git(['log', '--format=%s', 'main'], cwd: remote)
                  .trim()
                  .split('\n'),
              [
                'bob adds file',
                'bob edits bottom',
                'alice adds file',
                'alice edits top',
                'initial'
              ]);
          expect(git(['status', '--porcelain'], cwd: a), isEmpty);
          expect(git(['status', '--porcelain'], cwd: b), isEmpty);
        }
      });

      Future<(String, String, String, String)> conflictSetup() async {
        final (remote, a, b) = await setupPair();
        writeFile(
            a, 'shared.md', 'line 1\nline 2 alice\nline 3\nline 4\nline 5\n');
        await alice.commit(a, 'alice');
        await alice.sync(a, 'main');
        writeFile(b, 'b-only.md', 'b\n');
        await bob.commit(b, 'bob 1');
        writeFile(
            b, 'shared.md', 'line 1\nline 2 bob\nline 3\nline 4\nline 5\n');
        await bob.commit(b, 'bob 2');
        final before = File('$b/.git/refs/heads/main').readAsStringSync();
        final indexBefore = File('$b/.git/index').readAsBytesSync();
        final r = await bob.sync(b, 'main');
        expect(r.outcome, SyncOutcome.conflict);
        expect(r.conflictedFiles, ['shared.md']);
        // Nothing moved.
        expect(File('$b/.git/refs/heads/main').readAsStringSync(), before);
        expect(File('$b/.git/index').readAsBytesSync(), indexBefore);
        expect(readFile(b, 'shared.md'), contains('line 2 bob'));
        expect(readFile(b, 'b-only.md'), 'b\n');
        expect(await bob.status(b, 'main'), (clean: true, unpushed: 2));
        if (hasGit) expect(git(['status', '--porcelain'], cwd: b), isEmpty);
        return (remote, a, b, before);
      }

      test('conflict then abort', () async {
        final (_, _, b, before) = await conflictSetup();
        final r = await bob.resolve(b, 'main', ConflictResolution.abort);
        expect(r.outcome, isNot(SyncOutcome.conflict));
        expect(File('$b/.git/refs/heads/main').readAsStringSync(), before);
        expect(readFile(b, 'shared.md'), contains('line 2 bob'));
      });

      test('conflict then keep remote', () async {
        final (_, a, b, _) = await conflictSetup();
        final r = await bob.resolve(b, 'main', ConflictResolution.keepRemote);
        expect(r.outcome, SyncOutcome.fastForwarded);
        expect(readFile(b, 'shared.md'), contains('line 2 alice'));
        expect(File('$b/b-only.md').existsSync(), isFalse);
        expect(await bob.status(b, 'main'), (clean: true, unpushed: 0));
        expect((await bob.sync(b, 'main')).outcome, SyncOutcome.upToDate);
        expect((await alice.sync(a, 'main')).outcome, SyncOutcome.upToDate);
      });

      test('conflict then force push local', () async {
        final (remote, a, b, _) = await conflictSetup();
        final r =
            await bob.resolve(b, 'main', ConflictResolution.forcePushLocal);
        expect(r.outcome, SyncOutcome.pushed);
        expect(await bob.status(b, 'main'), (clean: true, unpushed: 0));
        // Alice now diverges from the rewritten remote; her change conflicts.
        final ra = await alice.sync(a, 'main');
        expect(ra.outcome, SyncOutcome.conflict);
        expect(
            (await alice.resolve(a, 'main', ConflictResolution.keepRemote))
                .outcome,
            SyncOutcome.fastForwarded);
        expect(readFile(a, 'shared.md'), contains('line 2 bob'));
        expect(readFile(a, 'b-only.md'), 'b\n');
        if (hasGit) git(['fsck', '--strict', '--no-dangling'], cwd: remote);
      });

      test('force push is refused when the remote moved since fetch', () async {
        final (_, a, b, _) = await conflictSetup();
        writeFile(a, 'a.md', 'moved on\n');
        await alice.commit(a, 'alice again');
        expect((await alice.sync(a, 'main')).outcome, SyncOutcome.pushed);
        await expectLater(
          bob.resolve(b, 'main', ConflictResolution.forcePushLocal),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', contains('changed since'))),
        );
        expect((await alice.sync(a, 'main')).outcome, SyncOutcome.upToDate);
        expect(readFile(a, 'a.md'), 'moved on\n');
      });

      test('dirty tree and missing remote', () async {
        final (_, _, b) = await setupPair();
        writeFile(b, 'a.md', 'dirty\n');
        final r = await bob.sync(b, 'main');
        expect(r.outcome, SyncOutcome.dirtyTree);
        expect(r.conflictedFiles, ['a.md']);
        final local = tempDir();
        await bob.init(local, branch: 'main');
        expect((await bob.sync(local, 'main')).outcome, SyncOutcome.noRemote);
        expect(await bob.remoteUrl(local), isNull);
        final remote = bareRepo();
        await bob.setRemoteUrl(local, url(remote));
        expect(await bob.remoteUrl(local), url(remote));
        writeFile(local, 'x.md', 'x\n');
        await bob.commit(local, 'x');
        expect((await bob.sync(local, 'main')).outcome, SyncOutcome.pushed);
      });

      test('large fetches are stored as packs', () async {
        final (remote, a, b) = await setupPair();
        for (var i = 0; i < 120; i++) {
          writeFile(a, 'many/f$i.md', 'file $i\n');
        }
        await alice.commit(a, 'many files');
        await alice.sync(a, 'main');
        expect((await bob.sync(b, 'main')).outcome, SyncOutcome.fastForwarded);
        expect(
            Directory('$b/.git/objects/pack')
                .listSync()
                .where((f) => f.path.endsWith('.pack')),
            isNotEmpty);
        expect(readFile(b, 'many/f119.md'), 'file 119\n');
        expect(await bob.status(b, 'main'), (clean: true, unpushed: 0));
        if (hasGit) git(['fsck', '--strict', '--no-dangling'], cwd: b);
        if (hasGit) git(['fsck', '--strict', '--no-dangling'], cwd: remote);
      });
    });
  }

  test('a remote that never answers times out', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    server.listen(held.add);
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await server.close();
    });
    final backend = GitBackend(networkTimeout: const Duration(seconds: 1));
    final dir = '${tempDir()}/c';
    final sw = Stopwatch()..start();
    await expectLater(
      backend.clone('http://127.0.0.1:${server.port}/repo.git', dir,
          branch: 'main'),
      throwsA(isA<GitException>()
          .having((e) => e.message, 'message', contains('timeout'))),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
    expect(Directory(dir).existsSync(), isFalse);
  });
}
