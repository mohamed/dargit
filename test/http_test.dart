import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'http_server.dart';

void main() {
  group('smart HTTP (git http-backend)', skip: skipNoGit, () {
    late GitHttpServer server;
    late String root;
    setUp(() async {
      root = tempDir('http');
      git(['init', '-q', '--bare', '-b', 'main', 'notes.git'], cwd: root);
      server = await GitHttpServer.start(root, password: 'tok3n');
      addTearDown(server.close);
    });

    GitBackend backend(String name, {String token = 'tok3n'}) => GitBackend(
          auth: GitAuth(
              method: AuthMethod.httpsToken, username: '', password: token),
          authorName: name,
          authorEmail: '$name@x',
        );

    test('clone, push, fast-forward and rebase over HTTP', () async {
      final a = '${tempDir()}/a', b = '${tempDir()}/b';
      final alice = backend('alice'), bob = backend('bob');
      await alice.clone(server.url('notes.git'), a, branch: 'main');
      writeFile(a, 'n.md', '1\n2\n3\n4\n');
      await alice.commit(a, 'one');
      expect((await alice.sync(a, 'main')).outcome, SyncOutcome.pushed);
      await bob.clone(server.url('notes.git'), b, branch: 'main');
      expect(readFile(b, 'n.md'), '1\n2\n3\n4\n');

      writeFile(a, 'n.md', '1a\n2\n3\n4\n');
      await alice.commit(a, 'alice');
      expect((await alice.sync(a, 'main')).outcome, SyncOutcome.pushed);
      writeFile(b, 'n.md', '1\n2\n3\n4b\n');
      await bob.commit(b, 'bob');
      expect((await bob.sync(b, 'main')).outcome, SyncOutcome.rebased);
      expect((await alice.sync(a, 'main')).outcome, SyncOutcome.fastForwarded);
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
      final url =
          server.url('notes.git').replaceFirst('http://', 'http://git:tok3n@');
      await GitBackend().clone(url, dir, branch: 'main');
      expect(File('$dir/.git/HEAD').existsSync(), isTrue);
    });
  });

  test('clone a public repository over HTTPS', tags: ['network'], () async {
    final dir = '${tempDir()}/hello';
    final g = GitBackend();
    await g.clone('https://github.com/octocat/Hello-World.git', dir,
        branch: 'master');
    expect(File('$dir/README').existsSync(), isTrue);
    expect(await g.status(dir, 'master'), (clean: true, unpushed: 0));
    expect((await g.sync(dir, 'master')).outcome, SyncOutcome.upToDate);
    final hist = await g.fileHistory(dir, 'README');
    expect(hist, isNotEmpty);
    if (hasGit) git(['fsck', '--strict', '--no-dangling'], cwd: dir);
  });
}
