// What a hostile repository or server must not be able to do, with git's
// own checks as the reference.
import 'dart:convert';
import 'dart:io';

import 'package:dargit/dargit.dart';
import 'package:dargit/src/paths.dart';
import 'package:dargit/src/transport/local.dart';
import 'package:dargit/src/transport/transport.dart';
import 'package:dargit/src/util.dart' show GitError;
import 'package:test/test.dart';

import 'channels.dart';
import 'golden.dart';
import 'helpers.dart';

/// A tree object (raw entries), written with `git hash-object --literally`
/// since git refuses to create bad trees itself.
Future<String> rawTree(String d, List<(String mode, String name, String id)> e,
    ObjectFormat fmt) async {
  final bytes = <int>[];
  for (final (mode, name, id) in e) {
    bytes
      ..addAll(utf8.encode('$mode $name'))
      ..add(0)
      ..addAll([
        for (var i = 0; i < id.length; i += 2)
          int.parse(id.substring(i, i + 2), radix: 16)
      ]);
  }
  return utf8
      .decode(await cliBytes(
          ['hash-object', '-t', 'tree', '-w', '--literally', '--stdin'], d,
          input: bytes))
      .trim();
}

void main() {
  group('names are checked like git checks them', skip: skipNoGit, () {
    test('ref names, against git check-ref-format', () {
      for (final name in [
        'refs/heads/main',
        'refs/heads/feature/x',
        'refs/heads/a.b',
        'refs/heads/../../../evil',
        'refs/heads/a..b',
        'refs/heads/.hidden',
        'refs/heads/x.lock',
        'refs/heads/x.',
        'refs/heads/a b',
        'refs/heads/a~1',
        'refs/heads/a^',
        'refs/heads/a:b',
        'refs/heads/a?',
        'refs/heads/a*',
        'refs/heads/a[',
        'refs/heads/a\\b',
        'refs/heads/a@{1}',
        'refs/heads//double',
        'refs/heads/trailing/',
        '@',
        'refs/heads/\x7f',
      ]) {
        final git = runGit(['check-ref-format', name], '.').exitCode == 0;
        expect(isValidRefName(name), git, reason: name);
      }
    });

    test('working-tree paths, against git update-index', () {
      final d = gitRepo(ObjectFormat.sha1);
      final blob = cli(['rev-parse', 'HEAD:a.md'], d).trim();
      for (final path in [
        'ok.md',
        'dir/ok.md',
        '.gitignore',
        '.github/workflows/ci.yml',
        'a.git',
        '..',
        '../outside',
        'dir/../x',
        './x',
        '.git/config',
        '.GIT/config',
        'dir/.git/hooks/x',
        '.git./config',
        '.git /config',
        'git~1/config',
        '.git::\$INDEX_ALLOCATION/config',
        '.g‌it/config',
        'a\\b',
        'x\\.git\\config',
        '..\\x',
        'dir//x',
        '/abs',
      ]) {
        final git = runGit([
              '-c', 'core.protectNTFS=true', //
              '-c', 'core.protectHFS=true',
              'update-index', '--add', '--cacheinfo', '100644,$blob,$path',
            ], d)
                .exitCode ==
            0;
        expect(isSafeWorktreePath(path), git, reason: path);
        // git for Windows also refuses any backslash.
        if (path.contains('\\')) {
          expect(isSafeWorktreePath(path, windows: true), isFalse);
        }
      }
    });
  });

  for (final fmt in ObjectFormat.values) {
    group('${fmt.name}:', skip: skipNoGit, () {
      test('a tree that reaches into .git or out of the work tree', () async {
        final dg = goldenGit();
        final d = gitRepo(fmt);
        final blob = cli(['rev-parse', 'HEAD:a.md'], d).trim();
        final config = await rawTree(d, [('100644', 'config', blob)], fmt);
        for (final (name, inner) in [
          ('.GIT', config),
          ('..', await rawTree(d, [('100644', 'escaped', blob)], fmt)),
          ('git~1', config),
        ]) {
          final tree = await rawTree(
              d, [('100644', 'a.md', blob), ('40000', name, inner)], fmt);
          final evil = cli(['commit-tree', tree, '-m', 'evil $name'], d).trim();
          final root = tempDir('hostile');
          final t = Twin('$root/cli', '$root/dg');
          cli(['clone', '-q', d, t.cliDir], root);
          await dg.clone(d, t.dgDir);
          final configBefore = readFile(t.dgDir, '.git/config');
          for (final dir in t.dirs) {
            cli(['fetch', '-q', d, evil], dir);
          }
          // git refuses ("invalid path"); so does dargit, writing nothing.
          expect(runGit(['reset', '-q', '--hard', evil], t.cliDir).exitCode,
              isNot(0));
          await expectLater(
              dg.resetHard(t.dgDir, evil),
              throwsA(isA<GitException>().having(
                  (e) => e.message, 'message', contains('invalid path'))));
          expect(readFile(t.dgDir, '.git/config'), configBefore);
          expect(File('$root/escaped').existsSync(), isFalse);
          // git's view of both is the same (no fsck: the bad objects are
          // there on purpose).
          expect(describe(t.dgDir), describe(t.cliDir), reason: name);
        }
      });

      test('ref names git would reject are ignored when fetching', () async {
        final d = gitRepo(fmt);
        final remote = '${tempDir('funny')}/r.git';
        cli(['clone', '-q', '--bare', d, remote], d);
        final head = cliRevParse(remote, 'HEAD')!;
        debugTransportFactory = (url, o) => ChannelTransport(GitChannel(
              remote,
              extraRefs: [
                '$head refs/heads/../../../../escaped',
                '$head refs/heads/bad~name',
              ],
            ));
        addTearDown(() => debugTransportFactory = null);
        final root = tempDir('funnyclone');
        await goldenGit(useIsolates: false).clone(remote, '$root/dg');
        cli(['clone', '-q', remote, '$root/cli'], root);
        await Twin('$root/cli', '$root/dg').expectSame(goldenGit());
        expect(Directory(root).listSync().map((e) => e.path).toSet(),
            {'$root/cli', '$root/dg'});
      });
    });
  }

  group('input from the app', skip: skipNoGit, () {
    test('a URL cannot inject config, as git escapes it', () async {
      final dg = goldenGit();
      final d = gitRepo(ObjectFormat.sha1);
      const url = 'https://example.com/r.git\n[core]\n\tsshCommand = evil\t\b';
      await dg.remoteAdd(d, url);
      expect(cli(['config', 'remote.origin.url'], d), '$url\n');
      expect(runGit(['config', 'core.sshCommand'], d).exitCode, isNot(0));
      expect(await dg.remoteGetUrl(d), url);
    });

    test('remote names and push destinations are checked like git', () async {
      final dg = goldenGit();
      final d = gitRepo(ObjectFormat.sha1);
      for (final name in ['a b', '../x', 'x.lock', '.hidden']) {
        expect(runGit(['remote', 'add', name, '/tmp/x'], d).exitCode, isNot(0));
        await expectLater(dg.remoteAdd(d, '/tmp/x', remote: name),
            throwsA(isA<GitException>()),
            reason: name);
      }
      final remote = '${tempDir('pushcheck')}/r.git';
      cli(['init', '-q', '--bare', remote], d);
      await dg.remoteAdd(d, remote);
      expect(runGit(['push', 'origin', 'HEAD:refs/heads/a..b'], d).exitCode,
          isNot(0));
      await expectLater(
          dg.push(d, 'HEAD:refs/heads/a..b'),
          throwsA(isA<GitException>().having(
              (e) => e.message, 'message', contains('invalid refspec'))));
      // The local receiver refuses such names from any client too.
      final s = await LocalTransport(remote).openReceive();
      await expectLater(
          s.push([
            RefUpdate('refs/heads/../../x', ObjectFormat.sha1.zeroId,
                cliRevParse(d, 'HEAD')!)
          ], null),
          throwsA(isA<GitError>()
              .having((e) => e.message, 'message', contains('funny refname'))));
      await s.close();
    });
  });

  group('HTTP redirects', () {
    test('credentials are not sent to another host', () async {
      final seen = <String, String?>{};
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => other.close(force: true));
      other.listen((r) async {
        seen['other'] = r.headers.value(HttpHeaders.authorizationHeader);
        r.response.statusCode = 404;
        await r.response.close();
      });
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => first.close(force: true));
      first.listen((r) async {
        seen['first'] = r.headers.value(HttpHeaders.authorizationHeader);
        r.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader,
              'http://127.0.0.1:${other.port}${r.uri}');
        await r.response.close();
      });
      await expectLater(
          goldenGit(credentials: const UserPassword('me', 'secret'))
              .lsRemote('http://127.0.0.1:${first.port}/r.git'),
          throwsA(isA<GitException>()));
      expect(seen['first'], startsWith('Basic '));
      expect(seen.containsKey('other'), isTrue);
      expect(seen['other'], isNull);
    });

    test('redirect loops end', () async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => s.close(force: true));
      s.listen((r) async {
        r.response
          ..statusCode = 301
          ..headers.set(HttpHeaders.locationHeader, r.uri.toString());
        await r.response.close();
      });
      await expectLater(
          goldenGit().lsRemote('http://127.0.0.1:${s.port}/r.git'),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', contains('too many'))));
    });
  });
}
