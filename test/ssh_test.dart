import 'dart:convert';
import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:dartgit/src/transport/ssh.dart';
import 'package:dartgit/src/transport/transport.dart';
import 'package:dartssh2/dartssh2.dart' show SSHKeyPair;
import 'package:test/test.dart';

import 'helpers.dart';
import 'ssh_agent_server.dart';

String? _which(String name) {
  for (final dir in [
    ...(Platform.environment['PATH'] ?? '').split(':'),
    '/usr/sbin',
    '/usr/local/sbin',
    '/sbin',
  ]) {
    final f = File('$dir/$name');
    if (dir.isNotEmpty && f.existsSync()) return f.path;
  }
  return null;
}

void _run(String exe, List<String> args) {
  final r = Process.runSync(exe, args);
  if (r.exitCode != 0) fail('$exe ${args.join(' ')}: ${r.stderr}');
}

/// A throwaway sshd on localhost accepting the given public keys for the
/// current user.
class Sshd {
  Sshd._(this.process, this.port, this.dir);
  final Process process;
  final int port;
  final String dir;

  static Future<Sshd> start(String dir, String authorizedKeys) async {
    final sshd = _which('sshd')!;
    _run(_which('ssh-keygen')!,
        ['-q', '-t', 'ed25519', '-N', '', '-f', '$dir/host_key']);
    File('$dir/authorized_keys').writeAsStringSync(authorizedKeys);
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    File('$dir/sshd_config').writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_key
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
''');
    final p = await Process.start(sshd, ['-D', '-e', '-f', '$dir/sshd_config']);
    p.stdout.drain<void>().ignore();
    p.stderr.drain<void>().ignore();
    for (var i = 0; i < 50; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', port);
        s.destroy();
        return Sshd._(p, port, dir);
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    p.kill();
    fail('sshd did not start');
  }

  void stop() => process.kill();
}

final String _user = Platform.environment['USER'] ??
    (Process.runSync('id', ['-un']).stdout as String).trim();

void main() {
  final missing = [
    if (_which('sshd') == null) 'sshd',
    if (_which('ssh-keygen') == null) 'ssh-keygen',
    if (!hasGit) 'git',
  ];

  test('SSH URL parsing', () {
    final o =
        TransportOptions(auth: GitAuth(), timeout: const Duration(seconds: 1));
    final scp = openTransport('git@github.com:me/notes.git', o) as SshTransport;
    expect([scp.user, scp.host, scp.port, scp.path],
        ['git', 'github.com', 22, 'me/notes.git']);
    final url = openTransport('ssh://bob@example.org:2222/srv/notes.git', o)
        as SshTransport;
    expect([url.user, url.host, url.port, url.path],
        ['bob', 'example.org', 2222, '/srv/notes.git']);
    expect(url.hostKeyName, '[example.org]:2222');
    final home =
        openTransport('ssh://example.org/~/notes.git', o) as SshTransport;
    expect([home.user, home.path], [null, '~/notes.git']);
  });

  group('against a local sshd',
      tags: ['ssh'],
      skip: missing.isEmpty ? null : 'missing ${missing.join(', ')}', () {
    Sshd? server;
    int port() => server!.port;
    late String keys, remote, known;
    const passphrase = 'correct horse';

    setUpAll(() async {
      if (missing.isNotEmpty) {
        fail('cannot run SSH tests: missing ${missing.join(', ')}');
      }
      keys = Directory.systemTemp.createTempSync('dartgit_ssh').path;
      final keygen = _which('ssh-keygen')!;
      _run(keygen,
          ['-q', '-t', 'ed25519', '-N', passphrase, '-f', '$keys/id_ed25519']);
      _run(keygen, [
        '-q',
        '-t',
        'rsa',
        '-b',
        '2048',
        '-m',
        'PEM',
        '-N',
        '',
        '-f',
        '$keys/id_rsa'
      ]);
      final authorized = '${File('$keys/id_ed25519.pub').readAsStringSync()}'
          '${File('$keys/id_rsa.pub').readAsStringSync()}';
      // The client must derive the public key itself.
      File('$keys/id_ed25519.pub').deleteSync();
      File('$keys/id_rsa.pub').deleteSync();
      server = await Sshd.start(keys, authorized);
    });
    tearDownAll(() {
      server?.stop();
      if (server != null) Directory(keys).deleteSync(recursive: true);
    });
    setUp(() {
      final root = tempDir('sshremote');
      remote = '$root/notes.git';
      git(['init', '-q', '--bare', '-b', 'main', remote], cwd: root);
      known = '${tempDir()}/known_hosts.json';
    });

    String url() => 'ssh://$_user@127.0.0.1:${port()}$remote';
    GitBackend keyBackend(String key, {String? pass}) => GitBackend(
          auth: GitAuth(
              method: AuthMethod.sshKey,
              sshKeyPath: '$keys/$key',
              sshPassphrase: pass),
          knownHostsPath: known,
          authorName: key,
          authorEmail: '$key@x',
        );

    test('clone, push, rebase with key files; host key pinned', () async {
      final ed = keyBackend('id_ed25519', pass: passphrase),
          rsa = keyBackend('id_rsa');
      final a = '${tempDir()}/a', b = '${tempDir()}/b';
      await ed.clone(url(), a, branch: 'main');
      writeFile(a, 'n.md', '1\n2\n3\n');
      await ed.commit(a, 'one');
      expect((await ed.sync(a, 'main')).outcome, SyncOutcome.pushed);
      await rsa.clone(url(), b, branch: 'main');
      writeFile(a, 'n.md', '1a\n2\n3\n');
      await ed.commit(a, 'a');
      await ed.sync(a, 'main');
      writeFile(b, 'n.md', '1\n2\n3b\n');
      await rsa.commit(b, 'b');
      expect((await rsa.sync(b, 'main')).outcome, SyncOutcome.rebased);
      expect(readFile(b, 'n.md'), '1a\n2\n3b\n');
      git(['fsck', '--strict', '--no-dangling'], cwd: remote);

      final pins =
          jsonDecode(File(known).readAsStringSync()) as Map<String, dynamic>;
      expect(pins.keys, ['[127.0.0.1]:${port()}']);
      expect(pins.values.single, startsWith('SHA256:'));
      File(known).writeAsStringSync(
          jsonEncode({'[127.0.0.1]:${port()}': 'SHA256:other'}));
      await expectLater(
          ed.sync(a, 'main'),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', contains('changed'))));
    });

    test('authentication errors are reported', () async {
      await expectLater(
          keyBackend('id_ed25519')
              .clone(url(), '${tempDir()}/x', branch: 'main'),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', contains('passphrase'))));
      await expectLater(
          GitBackend(knownHostsPath: known)
              .clone(url(), '${tempDir()}/y', branch: 'main'),
          throwsA(isA<GitException>().having(
              (e) => e.message, 'message', contains('authentication'))));
    });

    test('ssh agent', () async {
      final pair = SSHKeyPair.fromPem(
          File('$keys/id_ed25519').readAsStringSync(), passphrase);
      final sock = '${Directory.systemTemp.createTempSync('dga').path}/agent';
      final agent = await TestAgent.start(sock, pair);
      addTearDown(agent.close);
      final g = GitBackend(
          auth: GitAuth(method: AuthMethod.sshAgent, sshKeyPath: sock),
          knownHostsPath: known);
      final dir = '${tempDir()}/c';
      await g.clone(url(), dir, branch: 'main');
      expect(await g.isRepository(dir), isTrue);
    });
  });
}
