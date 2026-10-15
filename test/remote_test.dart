import 'dart:convert';
import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:dartgit/src/transport/process.dart';
import 'package:dartgit/src/transport/transport.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// How tests reach the bare "server" repository.
enum Via { path, fileUrl, gitCli }

void main() {
  for (final fmt in ObjectFormat.values) {
    group(fmt.name, () {
      for (final via in Via.values) {
        group('via ${via.name}', skip: via == Via.gitCli ? skipNoGit : null,
            () {
          late Git alice, bob;
          setUp(() {
            final inProcess = via == Via.gitCli;
            if (inProcess) {
              debugTransportFactory = (url, o) => ProcessTransport(url);
              addTearDown(() => debugTransportFactory = null);
            }
            alice = Git(
                authorName: 'Alice',
                authorEmail: 'a@x',
                useIsolates: !inProcess);
            bob = Git(
                authorName: 'Bob', authorEmail: 'b@x', useIsolates: !inProcess);
          });
          String url(String path) =>
              via == Via.fileUrl ? Uri.file(path).toString() : path;

          Future<String> bare() async {
            final dir = tempDir('remote');
            await alice.init(dir,
                objectFormat: fmt, initialBranch: 'main', bare: true);
            return dir;
          }

          Future<void> commitAll(Git g, String dir, String message) async {
            await g.add(dir, ['.']);
            expect(await g.commit(dir, message), isNotNull);
          }

          Future<int> ahead(Git g, String dir) =>
              g.revListCount(dir, 'main', exclude: 'origin/main');
          Future<int> behind(Git g, String dir) =>
              g.revListCount(dir, 'origin/main', exclude: 'main');

          /// A remote with one commit on main, cloned as alice and bob.
          Future<(String remote, String a, String b)> setupPair() async {
            final remote = await bare();
            final a = '${tempDir()}/a', b = '${tempDir()}/b';
            await alice.clone(url(remote), a, branch: 'main');
            writeFile(
                a, 'shared.md', 'line 1\nline 2\nline 3\nline 4\nline 5\n');
            writeFile(a, 'a.md', 'a\n');
            await commitAll(alice, a, 'initial');
            await alice.push(a, 'main');
            await bob.clone(url(remote), b);
            expect(readFile(b, 'shared.md'), startsWith('line 1'));
            return (remote, a, b);
          }

          test('clone of an empty remote, first push', () async {
            final remote = await bare();
            final dir = '${tempDir()}/clone';
            await alice.clone(url(remote), dir, branch: 'notes');
            expect(await alice.remoteGetUrl(dir), url(remote));
            expect(await alice.objectFormat(dir), fmt,
                reason: 'clone takes the remote object format');
            if (hasGit) {
              expect(
                  git(['rev-parse', '--show-object-format'], cwd: dir).trim(),
                  fmt.name);
            }
            expect(File('$dir/.git/HEAD').readAsStringSync(),
                'ref: refs/heads/notes\n');
            await alice.fetch(dir);
            expect(await alice.revParse(dir, 'origin/notes'), isNull);
            writeFile(dir, 'n.md', 'n\n');
            await commitAll(alice, dir, 'first');
            await alice.push(dir, 'notes');
            expect(await alice.revParse(dir, 'origin/notes'),
                await alice.revParse(dir, 'HEAD'));
            if (hasGit) {
              git(['fsck', '--strict', '--no-dangling'], cwd: remote);
              expect(
                  git(['log', '--format=%s', 'notes'], cwd: remote), 'first\n');
            }
          });

          test('clone without -b uses the remote HEAD; missing -b fails',
              () async {
            final (remote, _, b) = await setupPair();
            expect(File('$b/.git/HEAD').readAsStringSync(),
                'ref: refs/heads/main\n');
            final dir = '${tempDir()}/x';
            await expectLater(
              bob.clone(url(remote), dir, branch: 'mian'),
              throwsA(isA<GitException>()
                  .having((e) => e.operation, 'operation', 'clone')
                  .having(
                      (e) => e.message,
                      'message',
                      'Remote branch mian not found in upstream origin '
                          '(branches: main)')),
            );
            expect(Directory(dir).existsSync(), isFalse);
          });

          test('fetch, fast-forward with reset --hard, prune', () async {
            final (remote, a, b) = await setupPair();
            writeFile(a, 'a.md', 'a2\n');
            writeFile(a, 'new/n.md', 'n\n');
            await commitAll(alice, a, 'second');
            await alice.push(a, 'main');
            await bob.fetch(b, prune: true);
            expect((await ahead(bob, b), await behind(bob, b)), (0, 1));
            await bob.resetHard(b, 'origin/main');
            expect(readFile(b, 'a.md'), 'a2\n');
            expect(readFile(b, 'new/n.md'), 'n\n');
            expect(await bob.status(b), isEmpty);
            if (hasGit) {
              expect(git(['status', '--porcelain'], cwd: b), isEmpty);
              git(['branch', 'tmp', 'main'], cwd: remote);
              await bob.fetch(b);
              expect(await bob.revParse(b, 'origin/tmp'), isNotNull);
              git(['branch', '-D', 'tmp'], cwd: remote);
              await bob.fetch(b);
              expect(await bob.revParse(b, 'origin/tmp'), isNotNull,
                  reason: 'no --prune');
              await bob.fetch(b, prune: true);
              expect(await bob.revParse(b, 'origin/tmp'), isNull);
              expect(git(['reflog', '--format=%gs', 'origin/main'], cwd: b),
                  'fetch: fast-forward\nclone: storing head\n');
            }
          });

          test('a non-fast-forward push is rejected', () async {
            final (_, a, b) = await setupPair();
            writeFile(a, 'a.md', 'alice\n');
            await commitAll(alice, a, 'alice');
            await alice.push(a, 'main');
            writeFile(b, 'b.md', 'bob\n');
            await commitAll(bob, b, 'bob');
            await expectLater(
                bob.push(b, 'main'),
                throwsA(isA<GitException>().having(
                    (e) => e.message, 'message', contains('fetch first'))));
            await bob.fetch(b);
            await expectLater(
                bob.push(b, 'main'),
                throwsA(isA<GitException>().having((e) => e.message, 'message',
                    contains('non-fast-forward'))));
          });

          test('rebase onto origin, then push', () async {
            final (remote, a, b) = await setupPair();
            writeFile(a, 'shared.md',
                'line 1 (alice)\nline 2\nline 3\nline 4\nline 5\n');
            await commitAll(alice, a, 'alice edits top');
            writeFile(a, 'alice.md', 'from alice\n');
            await commitAll(alice, a, 'alice adds file');
            await alice.push(a, 'main');

            writeFile(b, 'shared.md',
                'line 1\nline 2\nline 3\nline 4\nline 5 (bob)\n');
            await commitAll(bob, b, 'bob edits bottom');
            writeFile(b, 'bob.md', 'from bob\n');
            await commitAll(bob, b, 'bob adds file');
            writeFile(b, 'untracked.md', 'stays\n');
            await bob.fetch(b);
            expect((await ahead(bob, b), await behind(bob, b)), (2, 2));
            final r = await bob.rebase(b, 'origin/main');
            expect(r.ok, isTrue);
            expect(r.head, await bob.revParse(b, 'HEAD'));
            expect(readFile(b, 'shared.md'),
                'line 1 (alice)\nline 2\nline 3\nline 4\nline 5 (bob)\n');
            expect(readFile(b, 'alice.md'), 'from alice\n');
            expect(readFile(b, 'untracked.md'), 'stays\n');
            expect((await ahead(bob, b), await behind(bob, b)), (2, 0));
            await bob.push(b, 'main');

            await alice.fetch(a);
            await alice.resetHard(a, 'origin/main');
            expect(readFile(a, 'shared.md'), readFile(b, 'shared.md'));
            final hist = await alice.log(a, path: 'shared.md', follow: true);
            expect(hist.map((h) => h.subject),
                ['bob edits bottom', 'alice edits top', 'initial']);
            expect(hist.first.authorName, 'Bob');
            if (hasGit) {
              git(['fsck', '--strict', '--no-dangling'], cwd: remote);
              expect(
                  git(['log', '--format=%s|%an|%cn', 'main'], cwd: remote)
                      .trim()
                      .split('\n'),
                  [
                    'bob adds file|Bob|Bob',
                    'bob edits bottom|Bob|Bob',
                    'alice adds file|Alice|Alice',
                    'alice edits top|Alice|Alice',
                    'initial|Alice|Alice',
                  ]);
              expect(
                  git(['status', '--porcelain'], cwd: b), '?? untracked.md\n');
            }
          });

          test('rebase drops commits already upstream', () async {
            final (_, a, b) = await setupPair();
            writeFile(a, 'a.md', 'same\n');
            await commitAll(alice, a, 'a same');
            await alice.push(a, 'main');
            writeFile(b, 'a.md', 'same\n');
            await commitAll(bob, b, 'b same');
            writeFile(b, 'b.md', 'b');
            await commitAll(bob, b, 'b only');
            await bob.fetch(b);
            expect((await bob.rebase(b, 'origin/main')).ok, isTrue);
            expect((await bob.log(b)).map((e) => e.subject),
                ['b only', 'a same', 'initial']);
          });

          test('conflicting rebase is aborted; lease protects force push',
              () async {
            final (remote, a, b) = await setupPair();
            writeFile(a, 'shared.md', 'line 1\nline 2 alice\nline 3\n');
            await commitAll(alice, a, 'alice');
            await alice.push(a, 'main');
            writeFile(b, 'b-only.md', 'b\n');
            await commitAll(bob, b, 'bob 1');
            writeFile(b, 'shared.md', 'line 1\nline 2 bob\nline 3\n');
            await commitAll(bob, b, 'bob 2');
            final before = await bob.revParse(b, 'HEAD');
            final indexBefore = File('$b/.git/index').readAsBytesSync();
            await bob.fetch(b);
            final r = await bob.rebase(b, 'origin/main');
            expect(r.ok, isFalse);
            expect(r.conflicts, ['shared.md']);
            expect(r.head, before);
            expect(await bob.revParse(b, 'HEAD'), before);
            expect(File('$b/.git/index').readAsBytesSync(), indexBefore);
            expect(readFile(b, 'shared.md'), contains('line 2 bob'));
            expect(await bob.status(b), isEmpty);
            expect(Directory('$b/.git/rebase-merge').existsSync(), isFalse);

            // Alice pushes again: Bob's lease (his origin/main) is stale.
            writeFile(a, 'a.md', 'moved on\n');
            await commitAll(alice, a, 'alice again');
            await alice.push(a, 'main');
            await expectLater(
                bob.push(b, 'main', forceWithLease: true),
                throwsA(isA<GitException>().having(
                    (e) => e.message, 'message', contains('stale info'))));
            await bob.fetch(b);
            await bob.push(b, 'main', forceWithLease: true);
            expect(await bob.revParse(b, 'origin/main'), before);

            // Alice keeps the remote version.
            await alice.fetch(a);
            await alice.resetHard(a, 'origin/main');
            expect(readFile(a, 'shared.md'), contains('line 2 bob'));
            expect(File('$a/a.md').readAsStringSync(), 'a\n');
            if (hasGit) git(['fsck', '--strict', '--no-dangling'], cwd: remote);
          });

          test('push with a refspec', () async {
            final (remote, a, _) = await setupPair();
            writeFile(a, 'n.md', 'notes\n');
            await commitAll(alice, a, 'notes only');
            await alice.push(a, 'HEAD:notes');
            expect(await alice.revParse(a, 'origin/notes'),
                await alice.revParse(a, 'HEAD'));
            expect(await alice.revParse(a, 'origin/main'),
                isNot(await alice.revParse(a, 'HEAD')));
            await alice.push(a, 'HEAD');
            expect(await alice.revParse(a, 'origin/main'),
                await alice.revParse(a, 'HEAD'));
            await expectLater(
                alice.push(a, 'nope'),
                throwsA(isA<GitException>().having((e) => e.message, 'message',
                    'src refspec nope does not match any')));
            if (hasGit) {
              expect(git(['log', '-1', '--format=%s', 'notes'], cwd: remote),
                  'notes only\n');
            }
          });

          test('remote add, set-url, remove', () async {
            final dir = tempDir();
            await bob.init(dir, objectFormat: fmt);
            expect(await bob.remoteGetUrl(dir), isNull);
            await bob.remoteAdd(dir, '/tmp/one.git');
            await expectLater(bob.remoteAdd(dir, '/tmp/two.git'),
                throwsA(isA<GitException>()));
            await bob.remoteSetUrl(dir, 'git@example.com:me/two.git');
            expect(await bob.remoteGetUrl(dir), 'git@example.com:me/two.git');
            await bob.remoteRemove(dir);
            expect(await bob.remoteGetUrl(dir), isNull);
            if (hasGit) expect(git(['remote'], cwd: dir), isEmpty);
            await expectLater(bob.fetch(dir), throwsA(isA<GitException>()));
          });

          test('large fetches are stored as packs', () async {
            final (remote, a, b) = await setupPair();
            for (var i = 0; i < 120; i++) {
              writeFile(a, 'many/f$i.md', 'file $i\n');
            }
            await commitAll(alice, a, 'many files');
            await alice.push(a, 'main');
            await bob.fetch(b);
            await bob.resetHard(b, 'origin/main');
            expect(
                Directory('$b/.git/objects/pack')
                    .listSync()
                    .where((f) => f.path.endsWith('.pack')),
                isNotEmpty);
            expect(readFile(b, 'many/f119.md'), 'file 119\n');
            expect(await bob.status(b), isEmpty);
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
        final g = Git(networkTimeout: const Duration(seconds: 1));
        final dir = '${tempDir()}/c';
        final sw = Stopwatch()..start();
        await expectLater(
          g.clone('http://127.0.0.1:${server.port}/repo.git', dir),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', contains('timeout'))),
        );
        expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
        expect(Directory(dir).existsSync(), isFalse);
      });

      test('fetch and push refuse a remote with another object format',
          () async {
        final g = Git(authorName: 'a', authorEmail: 'a@x');
        final remote = tempDir('remote');
        await g.init(remote, bare: true, objectFormat: ObjectFormat.sha256);
        final dir = tempDir();
        await g.init(dir);
        await g.remoteAdd(dir, remote);
        await expectLater(
            g.fetch(dir),
            throwsA(isA<GitException>().having(
                (e) => e.message, 'message', contains('sha256 object ids'))));
        writeFile(dir, 'a.md', 'a');
        await g.add(dir, ['.']);
        await g.commit(dir, 'a');
        await expectLater(g.push(dir, 'master'), throwsA(isA<GitException>()));
      });

      test('show returns bytes', () async {
        final g = Git(authorName: 'a', authorEmail: 'a@x');
        final dir = tempDir();
        await g.init(dir, objectFormat: fmt);
        File('$dir/bin').writeAsBytesSync([0, 1, 2, 255]);
        await g.add(dir, ['.']);
        await g.commit(dir, 'bin');
        expect(await g.show(dir, 'HEAD', 'bin'), [0, 1, 2, 255]);
        expect(
            utf8.decode((await g.show(dir, 'HEAD', 'bin'))!,
                allowMalformed: true),
            isNotEmpty);
      });
    });
  }
}
