// Remote commands checked against the git CLI as the golden reference.
import 'dart:convert';
import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:dartgit/src/transport/process.dart';
import 'package:dartgit/src/transport/transport.dart';
import 'package:test/test.dart';

import 'golden.dart';
import 'helpers.dart';

/// How dartgit reaches the bare "server" repository.
enum Via { path, fileUrl, gitCli }

/// A bare repository seeded by the git CLI (identical ids every time):
/// `main` with two commits and a `notes` branch.
String seededRemote(ObjectFormat fmt, {bool empty = false}) {
  final root = tempDir('remote');
  final bare = '$root/origin.git';
  cli([
    'init',
    '-q',
    '--bare',
    '-b',
    'main',
    '--object-format=${fmt.name}',
    bare
  ], root);
  if (empty) return bare;
  final w = '$root/seed';
  cli(['clone', '-q', bare, w], root);
  writeFile(w, 'shared.md', 'line 1\nline 2\nline 3\nline 4\nline 5\n');
  writeFile(w, 'a.md', 'a\n');
  cli(['add', '-A'], w);
  cli(['commit', '-q', '-m', 'initial'], w);
  writeFile(w, 'dir/b.md', 'b\n');
  cli(['add', '-A'], w);
  cli(['commit', '-q', '-m', 'second'], w);
  cli(['push', '-q', 'origin', 'main'], w);
  cli(['push', '-q', 'origin', 'HEAD~1:refs/heads/notes'], w);
  return bare;
}

/// Commits in [dir] through the CLI and pushes to its origin (simulates
/// another user).
void otherUserPushes(String bare, void Function(String work) edit,
    {String refspec = 'main', bool force = false}) {
  final root = tempDir('other');
  final w = '$root/w';
  cli(['clone', '-q', bare, w], root);
  edit(w);
  cli(['add', '-A'], w);
  cli(['commit', '-q', '-m', 'from another user'], w);
  cli(['push', '-q', if (force) '-f', 'origin', refspec], w);
}

void main() {
  for (final fmt in ObjectFormat.values) {
    for (final via in Via.values) {
      group('${fmt.name} via ${via.name}:', skip: skipNoGit, () {
        late Git dg;
        setUp(() {
          final inProcess = via == Via.gitCli;
          if (inProcess) {
            debugTransportFactory = (url, o) => ProcessTransport(url);
            addTearDown(() => debugTransportFactory = null);
          }
          dg = goldenGit(useIsolates: !inProcess);
        });
        String url(String path) =>
            via == Via.fileUrl ? Uri.file(path).toString() : path;
        // git over v0 when dartgit is fed git's own upload-pack, so both
        // see the same advertisement.
        List<String> proto() =>
            via == Via.gitCli ? ['-c', 'protocol.version=0'] : [];

        /// `git clone <args>` and `Git.clone` of the same remote.
        Future<Twin> cloneBoth(String bare, {String? branch}) async {
          final root = tempDir('clones');
          final t = Twin('$root/cli', '$root/dg');
          cli([
            ...proto(),
            'clone',
            '-q',
            if (branch != null) ...['-b', branch],
            url(bare),
            t.cliDir
          ], root);
          await dg.clone(url(bare), t.dgDir, branch: branch);
          return t;
        }

        String config(String dir) =>
            runGit(['config', '--get-regexp', r'^(remote|branch)\.'], dir)
                .stdout as String;

        test('clone matches git clone', () async {
          final bare = seededRemote(fmt);
          for (final branch in [null, 'main', 'notes']) {
            final t = await cloneBoth(bare, branch: branch);
            await t.expectSame(dg, reason: 'clone -b $branch');
            expect(config(t.dgDir), config(t.cliDir));
            for (final ref in ['HEAD', 'refs/remotes/origin/main']) {
              expect(
                  runGit(['reflog', 'show', '--format=%gs', ref], t.dgDir)
                      .stdout,
                  runGit(['reflog', 'show', '--format=%gs', ref], t.cliDir)
                      .stdout,
                  reason: 'reflog $ref');
            }
            expect(await dg.remoteGetUrl(t.dgDir), url(bare));
          }
        });

        test('a detached or dangling remote HEAD is cloned as git clones it',
            () async {
          final bare = seededRemote(fmt);
          // HEAD detached at a commit no branch has.
          final detached = cli(
                  ['commit-tree', 'main^{tree}', '-p', 'main', '-m', 'loose'],
                  bare)
              .trim();
          cli(['update-ref', '--no-deref', 'HEAD', detached], bare);
          // git ls-remote also lists peeled tags (`^{}`); dartgit does not.
          expect(await dg.lsRemote(url(bare)), {
            for (final l
                in lines(cli([...proto(), 'ls-remote', url(bare)], bare)))
              if (!l.endsWith('^{}')) l.split('\t')[1]: l.split('\t')[0],
          });
          var t = await cloneBoth(bare);
          await t.expectSame(dg, reason: 'detached');
          expect(config(t.dgDir), config(t.cliDir));
          expect(cli(['reflog', '--format=%gs'], t.dgDir),
              cli(['reflog', '--format=%gs'], t.cliDir));
          // HEAD on a branch that does not exist: nothing is checked out.
          cli(['symbolic-ref', 'HEAD', 'refs/heads/none'], bare);
          t = await cloneBoth(bare);
          await t.expectSame(dg, reason: 'dangling');
          expect(config(t.dgDir), config(t.cliDir));
        });

        test('cloning an empty remote, and a missing branch, as git does',
            () async {
          final empty = seededRemote(fmt, empty: true);
          final t = await cloneBoth(empty);
          await t.expectSame(dg, reason: 'empty clone');
          expect(config(t.dgDir), config(t.cliDir));

          for (final bare in [empty, seededRemote(fmt)]) {
            final root = tempDir('miss');
            final r = runGit([
              ...proto(),
              'clone',
              '-q',
              '-b',
              'mian',
              url(bare),
              '$root/cli'
            ], root);
            expect(r.exitCode, isNot(0));
            await expectLater(
                dg.clone(url(bare), '$root/dg', branch: 'mian'),
                throwsA(isA<GitException>().having((e) => e.message, 'message',
                    'Remote branch mian not found in upstream origin')));
            expect(r.stderr,
                contains('Remote branch mian not found in upstream origin'));
            expect(Directory('$root/dg').existsSync(),
                Directory('$root/cli').existsSync());
          }
          final occupied = tempDir('occupied');
          writeFile(occupied, 'x', 'x');
          await expectLater(
              dg.clone(url(empty), occupied), throwsA(isA<GitException>()));
          expect(readFile(occupied, 'x'), 'x');
        });

        test('ls-remote matches git ls-remote', () async {
          final bare = seededRemote(fmt);
          cli(['tag', 'v1', 'main'], bare);
          final want = {
            for (final l
                in lines(cli([...proto(), 'ls-remote', url(bare)], bare)))
              l.split('\t')[1]: l.split('\t')[0],
          };
          expect(await dg.lsRemote(url(bare)), want);
        });

        test('fetch and fetch --prune match git', () async {
          final bare = seededRemote(fmt);
          final t = await cloneBoth(bare);
          otherUserPushes(bare, (w) => writeFile(w, 'a.md', 'a2\n'));
          otherUserPushes(bare, (w) => writeFile(w, 'new.md', 'n\n'),
              refspec: 'HEAD:refs/heads/topic');
          cli(['branch', '-D', 'notes'], bare);
          cli([...proto(), 'fetch', 'origin'], t.cliDir);
          await dg.fetch(t.dgDir);
          await t.expectSame(dg, reason: 'fetch');
          cli([...proto(), 'fetch', '--prune', 'origin'], t.cliDir);
          await dg.fetch(t.dgDir, prune: true);
          await t.expectSame(dg, reason: 'fetch --prune');
          for (final ref in ['origin/main', 'origin/topic']) {
            expect(cli(['reflog', 'show', '--format=%gs', ref], t.dgDir),
                cli(['reflog', 'show', '--format=%gs', ref], t.cliDir),
                reason: 'reflog $ref');
          }
          // Forced update on the remote.
          otherUserPushes(bare, (w) {
            cli(['reset', '-q', '--hard', 'HEAD~2'], w);
            writeFile(w, 'rewritten.md', 'r\n');
          }, force: true);
          cli([...proto(), 'fetch', 'origin'], t.cliDir);
          await dg.fetch(t.dgDir);
          await t.expectSame(dg, reason: 'forced update');
          expect(
              cli(['reflog', 'show', '--format=%gs', 'origin/main'], t.dgDir),
              cli(['reflog', 'show', '--format=%gs', 'origin/main'], t.cliDir));
          // Fast-forward like `git reset --hard origin/main`.
          cli(['reset', '-q', '--hard', 'origin/main'], t.cliDir);
          await dg.resetHard(t.dgDir, 'origin/main');
          await t.expectSame(dg, reason: 'reset to origin');
        });

        /// Twin remotes and twin clones: the CLI side pushes to its own
        /// remote, dartgit to its own.
        Future<(Twin, String, String)> twinRemotes() async {
          final r1 = seededRemote(fmt), r2 = seededRemote(fmt);
          final root = tempDir('pushes');
          final t = Twin('$root/cli', '$root/dg');
          cli([...proto(), 'clone', '-q', url(r1), t.cliDir], root);
          await dg.clone(url(r2), t.dgDir);
          await t.expectSame(dg);
          return (t, r1, r2);
        }

        Future<void> commitBoth(Twin t, String message) async {
          cli(['add', '-A'], t.cliDir);
          cli(['commit', '-q', '-m', message], t.cliDir);
          await dg.add(t.dgDir, ['.']);
          expect(
              await dg.commit(t.dgDir, message), cliRevParse(t.cliDir, 'HEAD'));
        }

        void expectSameRemotes(String r1, String r2) {
          expect(describe(r2, bare: true), describe(r1, bare: true));
          expectFsck(r2);
        }

        test('push matches git push', () async {
          final (t, r1, r2) = await twinRemotes();
          t.write('a.md', 'pushed\n');
          await commitBoth(t, 'local change');
          cli([...proto(), 'push', '-q', 'origin', 'main'], t.cliDir);
          await dg.push(t.dgDir, 'main');
          expectSameRemotes(r1, r2);
          await t.expectSame(dg, reason: 'after push');
          expect(
              cli(['reflog', 'show', '--format=%gs', 'origin/main'], t.dgDir),
              cli(['reflog', 'show', '--format=%gs', 'origin/main'], t.cliDir));

          // A refspec naming another destination, and a new branch.
          t.write('n.md', 'n\n');
          await commitBoth(t, 'for notes');
          cli([...proto(), 'push', '-q', 'origin', 'HEAD:topic'], t.cliDir);
          await dg.push(t.dgDir, 'HEAD:topic');
          expectSameRemotes(r1, r2);
          await t.expectSame(dg, reason: 'push HEAD:topic');
          // Pushing what the remote already has changes nothing.
          cli([...proto(), 'push', '-q', 'origin', 'HEAD:topic'], t.cliDir);
          await dg.push(t.dgDir, 'HEAD:topic');
          expectSameRemotes(r1, r2);
          await expectLater(
              dg.push(t.dgDir, 'nope'),
              throwsA(isA<GitException>().having((e) => e.message, 'message',
                  'src refspec nope does not match any')));
          expect(runGit(['push', 'origin', 'nope'], t.cliDir).stderr,
              contains('src refspec nope does not match any'));
        });

        test('non-fast-forward and force-with-lease behave like git', () async {
          final (t, r1, r2) = await twinRemotes();
          for (final r in [r1, r2]) {
            otherUserPushes(r, (w) => writeFile(w, 'a.md', 'remote\n'));
          }
          t.write('b.md', 'local\n');
          await commitBoth(t, 'local');
          // The remote moved: a plain push is rejected by both.
          final r = runGit([...proto(), 'push', 'origin', 'main'], t.cliDir);
          expect(r.exitCode, isNot(0));
          expect(r.stderr, contains('[rejected]'));
          await expectLater(
              dg.push(t.dgDir, 'main'),
              throwsA(isA<GitException>().having(
                  (e) => e.message, 'message', contains('[rejected]'))));
          // The lease is the stale origin/main: both refuse.
          final lease = runGit(
              [...proto(), 'push', '--force-with-lease', 'origin', 'main'],
              t.cliDir);
          expect(lease.exitCode, isNot(0));
          expect(lease.stderr, contains('stale info'));
          await expectLater(
              dg.push(t.dgDir, 'main', forceWithLease: true),
              throwsA(isA<GitException>().having(
                  (e) => e.message, 'message', contains('stale info'))));
          expectSameRemotes(r1, r2);
          // After a fetch the lease holds and both overwrite the remote.
          cli([...proto(), 'fetch', '-q', 'origin'], t.cliDir);
          await dg.fetch(t.dgDir);
          cli([
            ...proto(),
            'push',
            '-q',
            '--force-with-lease',
            'origin',
            'main'
          ], t.cliDir);
          await dg.push(t.dgDir, 'main', forceWithLease: true);
          expectSameRemotes(r1, r2);
        });

        test('rebase onto origin matches git rebase', () async {
          final (t, r1, r2) = await twinRemotes();
          for (final r in [r1, r2]) {
            otherUserPushes(
                r,
                (w) => writeFile(w, 'shared.md',
                    'line 1 remote\nline 2\nline 3\nline 4\nline 5\n'));
          }
          t.write(
              'shared.md', 'line 1\nline 2\nline 3\nline 4\nline 5 local\n');
          await commitBoth(t, 'local edit');
          t.write('mine.md', 'mine\n');
          await commitBoth(t, 'local file');
          t.write('untracked.md', 'stays\n');
          cli([...proto(), 'fetch', '-q', 'origin'], t.cliDir);
          await dg.fetch(t.dgDir);
          cli(['rebase', '-q', 'origin/main'], t.cliDir);
          final r = await dg.rebase(t.dgDir, 'origin/main');
          expect(r.ok, isTrue);
          expect(r.head, cliRevParse(t.cliDir, 'HEAD'));
          await t.expectSame(dg, reason: 'after rebase');
          cli([...proto(), 'push', '-q', 'origin', 'main'], t.cliDir);
          await dg.push(t.dgDir, 'main');
          expectSameRemotes(r1, r2);
        });

        test('a conflicting rebase stops where git rebase --abort leaves it',
            () async {
          final (t, r1, r2) = await twinRemotes();
          for (final r in [r1, r2]) {
            otherUserPushes(
                r,
                (w) => writeFile(w, 'shared.md',
                    'line 1\nline 2 remote\nline 3\nline 4\nline 5\n'));
          }
          t.write('b-only.md', 'b\n');
          await commitBoth(t, 'local 1');
          t.write(
              'shared.md', 'line 1\nline 2 local\nline 3\nline 4\nline 5\n');
          await commitBoth(t, 'local 2');
          cli([...proto(), 'fetch', '-q', 'origin'], t.cliDir);
          await dg.fetch(t.dgDir);
          final before = cliRevParse(t.dgDir, 'HEAD');
          final rebase = runGit(['rebase', 'origin/main'], t.cliDir);
          expect(rebase.exitCode, isNot(0));
          final conflicted =
              lines(cli(['diff', '--name-only', '--diff-filter=U'], t.cliDir));
          cli(['rebase', '--abort'], t.cliDir);
          final r = await dg.rebase(t.dgDir, 'origin/main');
          expect(r.ok, isFalse);
          expect(r.conflicts, conflicted);
          expect(r.head, before);
          await t.expectSame(dg, reason: 'after abort');
          expect(
              Directory('${t.dgDir}/.git/rebase-merge').existsSync(), isFalse);
          // Keep the remote version: reset --hard origin/main.
          cli(['reset', '-q', '--hard', 'origin/main'], t.cliDir);
          await dg.resetHard(t.dgDir, 'origin/main');
          await t.expectSame(dg, reason: 'keep remote');
        });

        test('remote add, set-url and remove match git remote', () async {
          final bare = seededRemote(fmt);
          final t = await cloneBoth(bare);
          cli(['remote', 'remove', 'origin'], t.cliDir);
          await dg.remoteRemove(t.dgDir);
          expect(config(t.dgDir), config(t.cliDir));
          await t.expectSame(dg, reason: 'remote remove');
          expect(await dg.remoteGetUrl(t.dgDir), isNull);
          cli(['remote', 'add', 'origin', '/tmp/one.git'], t.cliDir);
          await dg.remoteAdd(t.dgDir, '/tmp/one.git');
          expect(config(t.dgDir), config(t.cliDir));
          cli(['remote', 'set-url', 'origin', 'git@example.com:me/two.git'],
              t.cliDir);
          await dg.remoteSetUrl(t.dgDir, 'git@example.com:me/two.git');
          expect(config(t.dgDir), config(t.cliDir));
          // Errors where git errors.
          expect(
              runGit(['remote', 'add', 'origin', 'x'], t.cliDir).exitCode, 3);
          await expectLater(
              dg.remoteAdd(t.dgDir, 'x'), throwsA(isA<GitException>()));
          expect(runGit(['remote', 'set-url', 'nope', 'x'], t.cliDir).exitCode,
              isNot(0));
          await expectLater(dg.remoteSetUrl(t.dgDir, 'x', remote: 'nope'),
              throwsA(isA<GitException>()));
          expect(runGit(['remote', 'remove', 'nope'], t.cliDir).exitCode,
              isNot(0));
          await expectLater(dg.remoteRemove(t.dgDir, remote: 'nope'),
              throwsA(isA<GitException>()));
          await expectLater(
              dg.fetch(t.dgDir, remote: 'nope'), throwsA(isA<GitException>()));
        });

        test('large fetches are stored as packs git can read', () async {
          final bare = seededRemote(fmt);
          final t = await cloneBoth(bare);
          otherUserPushes(bare, (w) {
            for (var i = 0; i < 120; i++) {
              writeFile(w, 'many/f$i.md', 'file $i\n');
            }
          });
          cli([...proto(), 'fetch', '-q', 'origin'], t.cliDir);
          await dg.fetch(t.dgDir);
          cli(['reset', '-q', '--hard', 'origin/main'], t.cliDir);
          await dg.resetHard(t.dgDir, 'origin/main');
          await t.expectSame(dg);
          expect(
              Directory('${t.dgDir}/.git/objects/pack')
                  .listSync()
                  .where((f) => f.path.endsWith('.pack')),
              isNotEmpty);
        });
      });
    }

    test(
        '${fmt.name}: fetching from a remote with the other object format '
        'fails as in git',
        skip: skipNoGit, () async {
      final other = ObjectFormat.values.firstWhere((f) => f != fmt);
      final remote = seededRemote(other);
      final dir = tempDir();
      cli(['init', '-q', '--object-format=${fmt.name}'], dir);
      cli(['remote', 'add', 'origin', remote], dir);
      expect(runGit(['fetch', 'origin'], dir).exitCode, isNot(0));
      final dg = goldenGit();
      await expectLater(
          dg.fetch(dir),
          throwsA(isA<GitException>().having((e) => e.message, 'message',
              contains('${other.name} object ids'))));
      writeFile(dir, 'a.md', 'a');
      await dg.add(dir, ['.']);
      await dg.commit(dir, 'a');
      await expectLater(dg.push(dir, 'master'), throwsA(isA<GitException>()));
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
    final g = goldenGit(networkTimeout: const Duration(seconds: 1));
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

  test('a missing local remote is reported', () async {
    final g = goldenGit();
    await expectLater(
        g.clone('/nonexistent/repo.git', '${tempDir()}/c'),
        throwsA(isA<GitException>()
            .having((e) => e.message, 'message', contains('does not exist'))));
    final notRepo = tempDir();
    await expectLater(
        g.lsRemote(notRepo),
        throwsA(isA<GitException>().having(
            (e) => e.message, 'message', contains('not a Git repository'))));
    await expectLater(
        g.lsRemote('ftp://example.com/x'), throwsA(isA<GitException>()));
    expect(utf8.decode([]), isEmpty);
  });
}
