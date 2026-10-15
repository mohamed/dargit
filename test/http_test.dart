import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'http_server.dart';

void main() {
  for (final fmt in ObjectFormat.values) {
    group('smart HTTP (git http-backend, ${fmt.name})', skip: skipNoGit, () {
      late GitHttpServer server;
      late String root;
      setUp(() async {
        root = tempDir('http');
        git([
          'init',
          '-q',
          '--bare',
          '-b',
          'main',
          '--object-format=${fmt.name}',
          'notes.git'
        ], cwd: root);
        server = await GitHttpServer.start(root, password: 'tok3n');
        addTearDown(server.close);
      });

      Git backend(String name, {String token = 'tok3n'}) => Git(
            credentials: UserPassword('git', token),
            authorName: name,
            authorEmail: '$name@x',
          );

      Future<void> commitAll(Git g, String dir, String m) async {
        await g.add(dir, ['.']);
        await g.commit(dir, m);
      }

      test('clone, push, fetch and rebase over HTTP', () async {
        final a = '${tempDir()}/a', b = '${tempDir()}/b';
        final alice = backend('alice'), bob = backend('bob');
        await alice.clone(server.url('notes.git'), a, branch: 'main');
        writeFile(a, 'n.md', '1\n2\n3\n4\n');
        await commitAll(alice, a, 'one');
        await alice.push(a, 'main');
        await bob.clone(server.url('notes.git'), b, branch: 'main');
        expect(readFile(b, 'n.md'), '1\n2\n3\n4\n');

        writeFile(a, 'n.md', '1a\n2\n3\n4\n');
        await commitAll(alice, a, 'alice');
        await alice.push(a, 'main');
        writeFile(b, 'n.md', '1\n2\n3\n4b\n');
        await commitAll(bob, b, 'bob');
        await bob.fetch(b);
        expect((await bob.rebase(b, 'origin/main')).ok, isTrue);
        await bob.push(b, 'main');
        await alice.fetch(a);
        await alice.resetHard(a, 'origin/main');
        expect(readFile(a, 'n.md'), '1a\n2\n3\n4b\n');
        git(['fsck', '--strict', '--no-dangling'], cwd: '$root/notes.git');
        expect(server.requests, greaterThan(8));
      });

      test('wrong token is reported as an authentication failure', () async {
        final dir = '${tempDir()}/c';
        await expectLater(
          backend('eve', token: 'wrong')
              .clone(server.url('notes.git'), dir, branch: 'main'),
          throwsA(isA<GitException>().having(
              (e) => e.message, 'message', contains('authentication failed'))),
        );
        expect(Directory(dir).existsSync(), isFalse);
      });

      test('credentials in the URL are used', () async {
        final dir = '${tempDir()}/c';
        final url = server
            .url('notes.git')
            .replaceFirst('http://', 'http://git:tok3n@');
        await Git().clone(url, dir, branch: 'main');
        expect(File('$dir/.git/HEAD').existsSync(), isTrue);
      });
    });
  }

  test('clone a public repository over HTTPS', tags: ['network'], () async {
    final dir = '${tempDir()}/hello';
    final g = Git();
    await g.clone('https://github.com/octocat/Hello-World.git', dir);
    expect(File('$dir/README').existsSync(), isTrue);
    expect(await g.status(dir), isEmpty);
    await g.fetch(dir, prune: true);
    expect(await g.revListCount(dir, 'origin/master', exclude: 'HEAD'), 0);
    expect(await g.log(dir, path: 'README', follow: true), isNotEmpty);
    if (hasGit) git(['fsck', '--strict', '--no-dangling'], cwd: dir);
  });
}
