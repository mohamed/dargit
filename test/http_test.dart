// Smart HTTP checked against the git CLI talking to the same server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dargit/dargit.dart';
import 'package:test/test.dart';

import 'golden.dart';
import 'helpers.dart';
import 'http_server.dart';

/// An HTTP server answering every request with [handler].
Future<String> fakeServer(
    Future<void> Function(HttpRequest req) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((req) async {
    await req.drain<void>();
    await handler(req);
  });
  return 'http://127.0.0.1:${server.port}/repo.git';
}

void main() {
  for (final fmt in ObjectFormat.values) {
    group('${fmt.name} over smart HTTP:', skip: skipNoGit, () {
      late GitHttpServer server;
      late String root;
      final dg = goldenGit(credentials: const UserPassword('git', 'tok3n'));

      /// The URL git uses (credentials in the URL; git has no prompt here).
      String cliUrl(String repo) =>
          server.url(repo).replaceFirst('http://', 'http://git:tok3n@');

      setUp(() async {
        root = tempDir('http');
        for (final name in ['one.git', 'two.git']) {
          cli([
            'init',
            '-q',
            '--bare',
            '-b',
            'main',
            '--object-format=${fmt.name}',
            name
          ], root);
          // Seed both identically through the CLI.
          final w = '$root/seed-$name';
          cli(['clone', '-q', '$root/$name', w], root);
          writeFile(w, 'n.md', '1\n2\n3\n4\n');
          cli(['add', '-A'], w);
          cli(['commit', '-q', '-m', 'seed'], w);
          cli(['push', '-q', 'origin', 'main'], w);
        }
        server = await GitHttpServer.start(root, password: 'tok3n');
        addTearDown(server.close);
      });

      test('clone, push, fetch and rebase match git over the same server',
          () async {
        final c = tempDir('clones');
        final t = Twin('$c/cli', '$c/dg');
        await cliAsync(['clone', '-q', cliUrl('one.git'), t.cliDir], c);
        await dg.clone(server.url('two.git'), t.dgDir);
        await t.expectSame(dg, reason: 'clone');

        t.write('n.md', '1a\n2\n3\n4\n');
        cli(['commit', '-q', '-am', 'edit'], t.cliDir);
        await dg.commit(t.dgDir, 'edit', only: ['n.md']);
        await cliAsync(['push', '-q', 'origin', 'main'], t.cliDir);
        await dg.push(t.dgDir, 'main');
        expect(describe('$root/two.git', bare: true),
            describe('$root/one.git', bare: true));
        await t.expectSame(dg, reason: 'push');

        // Someone else pushes to each; both sides fetch and rebase.
        for (final name in ['one.git', 'two.git']) {
          final w = '$root/other-$name';
          cli(['clone', '-q', '$root/$name', w], root);
          writeFile(w, 'n.md', '1a\n2\n3\n4b\n');
          cli(['commit', '-q', '-am', 'other'], w);
          cli(['push', '-q', 'origin', 'main'], w);
        }
        t.write('local.md', 'l\n');
        cli(['add', '-A'], t.cliDir);
        cli(['commit', '-q', '-m', 'local'], t.cliDir);
        await dg.add(t.dgDir, ['.']);
        await dg.commit(t.dgDir, 'local');
        await cliAsync(['fetch', '-q', 'origin'], t.cliDir);
        await dg.fetch(t.dgDir, prune: true);
        cli(['rebase', '-q', 'origin/main'], t.cliDir);
        expect((await dg.rebase(t.dgDir, 'origin/main')).ok, isTrue);
        await t.expectSame(dg, reason: 'rebase');
        await cliAsync(['push', '-q', 'origin', 'main'], t.cliDir);
        await dg.push(t.dgDir, 'main');
        expect(describe('$root/two.git', bare: true),
            describe('$root/one.git', bare: true));
        expectFsck('$root/two.git');
        expect(await dg.lsRemote(server.url('two.git')), {
          for (final l
              in lines(await cliAsync(['ls-remote', cliUrl('one.git')], root)))
            l.split('\t')[1]: l.split('\t')[0],
        });
        expect(server.requests, greaterThan(8));
      });

      test('redirects are followed like git follows them', () async {
        final c = tempDir('moved');
        final moved =
            server.url('one.git').replaceFirst('/one.git', '/moved/one.git');
        await cliAsync([
          'clone',
          '-q',
          moved.replaceFirst('http://', 'http://git:tok3n@'),
          '$c/cli'
        ], c);
        await dg.clone(moved, '$c/dg');
        await Twin('$c/cli', '$c/dg').expectSame(dg);
        // The POST goes to the redirected location.
        writeFile('$c/dg', 'x.md', 'x');
        await dg.add('$c/dg', ['.']);
        await dg.commit('$c/dg', 'x');
        await dg.push('$c/dg', 'main');
        expect(
            cliRevParse('$root/one.git', 'main'), cliRevParse('$c/dg', 'HEAD'));
      });

      test('credentials: wrong token, none, and in the URL', () async {
        final c = tempDir('auth');
        final bad =
            server.url('one.git').replaceFirst('http://', 'http://git:wrong@');
        expect((await runGitAsync(['clone', '-q', bad, '$c/cli'], c)).exitCode,
            isNot(0));
        await expectLater(
            goldenGit(credentials: const UserPassword('git', 'wrong'))
                .clone(server.url('one.git'), '$c/dg'),
            throwsA(isA<GitException>().having((e) => e.message, 'message',
                contains('authentication failed'))));
        expect(Directory('$c/dg').existsSync(), isFalse);
        await expectLater(
            goldenGit().clone(server.url('one.git'), '$c/none'),
            throwsA(isA<GitException>().having((e) => e.message, 'message',
                contains('authentication required'))));
        await goldenGit().clone(cliUrl('one.git'), '$c/inurl');
        expect(await dg.revParse('$c/inurl', 'HEAD'),
            cliRevParse('$root/one.git', 'main'));
        // A missing repository on a reachable server.
        await expectLater(dg.clone(server.url('missing.git'), '$c/missing'),
            throwsA(isA<GitException>()));
        expect(
            (await runGitAsync(['ls-remote', cliUrl('missing.git')], c))
                .exitCode,
            isNot(0));
      });
    });
  }

  group('HTTP errors', () {
    final g = goldenGit();
    Future<void> fails(String url, Object message) => expectLater(
        g.lsRemote(url),
        throwsA(
            isA<GitException>().having((e) => e.message, 'message', message)));

    test('404, 403, 500 and a dumb server', () async {
      await fails(
          await fakeServer((r) async {
            r.response.statusCode = 404;
            await r.response.close();
          }),
          contains('not found'));
      await fails(
          await fakeServer((r) async {
            r.response.statusCode = 403;
            await r.response.close();
          }),
          contains('authentication required'));
      await fails(
          await fakeServer((r) async {
            r.response
              ..statusCode = 500
              ..write('server exploded\nmore');
            await r.response.close();
          }),
          'HTTP 500: server exploded');
      await fails(
          await fakeServer((r) async {
            r.response.statusCode = 502;
            await r.response.close();
          }),
          'HTTP 502');
      await fails(
          await fakeServer((r) async {
            r.response
              ..headers.contentType = ContentType.text
              ..write('0123456789abcdef refs/heads/main\n');
            await r.response.close();
          }),
          contains('smart HTTP'));
    });

    test('push to a repository the server does not have', () async {
      final url = await fakeServer((r) async {
        r.response.statusCode = 404;
        await r.response.close();
      });
      final d = gitRepo(ObjectFormat.sha1);
      cli(['remote', 'add', 'origin', url], d);
      expect((await runGitAsync(['push', 'origin', 'main'], d)).exitCode,
          isNot(0));
      await expectLater(
          g.push(d, 'main'),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', contains('not found'))));
    });

    test('bad advertisements', () async {
      Future<String> advertising(String body) => fakeServer((r) async {
            r.response.headers.contentType = ContentType.parse(
                'application/x-git-upload-pack-advertisement');
            r.response.write(body);
            await r.response.close();
          });
      await fails(await advertising('001e# service=wrong-service\n0000'),
          contains('bad service header'));
      await fails(await advertising('zzzz'), contains('bad pkt-line header'));
      await fails(await advertising('001e# service=git-upload-pack\n'),
          contains('unexpected end of stream'));
      await fails(
          await advertising('001e# service=git-upload-pack\n0000'
              '0012ERR no access\n'),
          contains('remote error: no access'));
    });

    test('a connection refused is a network error', () async {
      // Port 1 (tcpmux) is privileged and unused, so nothing answers; a
      // just-closed ephemeral port could be taken by a parallel test.
      await fails('http://127.0.0.1:1/x.git', contains('network error'));
    });
  });

  test('clone a public repository over HTTPS like git', tags: ['network'],
      () async {
    final root = tempDir('public');
    const url = 'https://github.com/octocat/Hello-World.git';
    final g = goldenGit();
    cli(['clone', '-q', url, '$root/cli'], root);
    await g.clone(url, '$root/dg');
    final t = Twin('$root/cli', '$root/dg');
    await t.expectSame(g);
    await g.fetch(t.dgDir, prune: true);
    expect(await g.log(t.dgDir, path: 'README', follow: true), isNotEmpty);
    expect(utf8.decode((await g.show(t.dgDir, 'HEAD', 'README'))!),
        readFile(t.cliDir, 'README'));
    unawaited(Future<void>.value());
  });
}
