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
    final o = TransportOptions(timeout: const Duration(seconds: 1));
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
    late String keys, remote, remote256, known;
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
      remote256 = '$root/notes256.git';
      git(['init', '-q', '--bare', '-b', 'main', remote], cwd: root);
      git([
        'init',
        '-q',
        '--bare',
        '-b',
        'main',
        '--object-format=sha256',
        remote256
      ], cwd: root);
      known = '${tempDir()}/known_hosts.json';
    });

    String url() => 'ssh://$_user@127.0.0.1:${port()}$remote';
    Git keyGit(String key, {String? pass}) => Git(
          credentials: SshKey('$keys/$key', passphrase: pass),
          verifyHostKey: pinTo(known),
          authorName: key,
          authorEmail: '$key@x',
        );

    Future<void> commitAll(Git g, String dir, String m) async {
      await g.add(dir, ['.']);
      await g.commit(dir, m);
    }

    test('SHA-256 repository over SSH', () async {
      final g = keyGit('id_rsa');
      final url256 = 'ssh://$_user@127.0.0.1:${port()}$remote256';
      final a = '${tempDir()}/a', b = '${tempDir()}/b';
      await g.clone(url256, a, branch: 'main');
      expect(await g.objectFormat(a), ObjectFormat.sha256);
      writeFile(a, 'n.md', 'n\n');
      await commitAll(g, a, 'one');
      await g.push(a, 'main');
      await g.clone(url256, b);
      expect(readFile(b, 'n.md'), 'n\n');
      git(['fsck', '--strict', '--no-dangling'], cwd: remote256);
    });

    test('clone, push, rebase with key files; host key pinned', () async {
      final ed = keyGit('id_ed25519', pass: passphrase), rsa = keyGit('id_rsa');
      final a = '${tempDir()}/a', b = '${tempDir()}/b';
      await ed.clone(url(), a, branch: 'main');
      writeFile(a, 'n.md', '1\n2\n3\n');
      await commitAll(ed, a, 'one');
      await ed.push(a, 'main');
      await rsa.clone(url(), b, branch: 'main');
      writeFile(a, 'n.md', '1a\n2\n3\n');
      await commitAll(ed, a, 'a');
      await ed.push(a, 'main');
      writeFile(b, 'n.md', '1\n2\n3b\n');
      await commitAll(rsa, b, 'b');
      await rsa.fetch(b);
      expect((await rsa.rebase(b, 'origin/main')).ok, isTrue);
      await rsa.push(b, 'main');
      expect(readFile(b, 'n.md'), '1a\n2\n3b\n');
      git(['fsck', '--strict', '--no-dangling'], cwd: remote);

      final pins =
          jsonDecode(File(known).readAsStringSync()) as Map<String, dynamic>;
      expect(pins.keys, ['[127.0.0.1]:${port()}']);
      expect(pins.values.single, startsWith('SHA256:'));
      File(known).writeAsStringSync(
          jsonEncode({'[127.0.0.1]:${port()}': 'SHA256:other'}));
      await expectLater(
          ed.fetch(a),
          throwsA(isA<GitException>().having((e) => e.message, 'message',
              contains('Host key verification failed'))));
    });

    test('authentication errors are reported', () async {
      await expectLater(
          keyGit('id_ed25519').clone(url(), '${tempDir()}/x'),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', contains('passphrase'))));
      await expectLater(
          Git(verifyHostKey: pinTo(known)).clone(url(), '${tempDir()}/y'),
          throwsA(isA<GitException>().having(
              (e) => e.message, 'message', contains('authentication'))));
    });

    test('ssh agent', () async {
      final pair = SSHKeyPair.fromPem(
          File('$keys/id_ed25519').readAsStringSync(), passphrase);
      final sock = '${Directory.systemTemp.createTempSync('dga').path}/agent';
      final agent = await TestAgent.start(sock, pair);
      addTearDown(agent.close);
      final g = Git(
          credentials: SshAgent(socketPath: sock), verifyHostKey: pinTo(known));
      final dir = '${tempDir()}/c';
      await g.clone(url(), dir, branch: 'main');
      expect(await g.isRepository(dir), isTrue);
    });
  });
}

/// Trust on first use, pinned in a JSON file `{host: fingerprint}`.
/// Top-level so the closure only captures [file] (it is sent to isolates).
HostKeyVerifier pinTo(String file) => (host, fingerprint) {
      final f = File(file);
      final known = f.existsSync()
          ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
          : <String, dynamic>{};
      final pinned = known[host];
      if (pinned != null) return pinned == fingerprint;
      f.writeAsStringSync(jsonEncode({...known, host: fingerprint}));
      return true;
    };
