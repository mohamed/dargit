import 'dart:convert';
import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:dartgit/src/transport/ssh.dart';
import 'package:dartgit/src/transport/transport.dart';
import 'package:dartssh2/dartssh2.dart' show SSHKeyPair;
import 'package:test/test.dart';

import 'golden.dart';
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
    if (_which('ssh') == null) 'ssh',
    if (!hasGit) 'git',
  ];

  test('SSH URLs are parsed like git parses them', () {
    final o = TransportOptions(timeout: const Duration(seconds: 1));
    SshTransport ssh(String url) => openTransport(url, o) as SshTransport;
    final scp = ssh('git@github.com:me/notes.git');
    expect([scp.user, scp.host, scp.port, scp.path, scp.hostKeyName],
        ['git', 'github.com', 22, 'me/notes.git', 'github.com']);
    final url = ssh('ssh://bob@example.org:2222/srv/notes.git');
    expect([url.user, url.host, url.port, url.path],
        ['bob', 'example.org', 2222, '/srv/notes.git']);
    expect(url.hostKeyName, '[example.org]:2222');
    final home = ssh('ssh://example.org/~/notes.git');
    expect([home.user, home.path], [null, '~/notes.git']);
    expect(ssh('git+ssh://me@h/x').user, 'me');
    expect(ssh('host:relative/path').path, 'relative/path');
    expect(shellQuote("it's"), "'it'\\''s'");
  });

  group('against a local sshd',
      tags: ['ssh'],
      skip: missing.isEmpty ? null : 'missing ${missing.join(', ')}', () {
    Sshd? server;
    int port() => server!.port;
    late String keys, known;
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
      _run(keygen, ['-q', '-t', 'ed25519', '-N', '', '-f', '$keys/cli_key']);
      final authorized = [
        for (final k in ['id_ed25519', 'id_rsa', 'cli_key'])
          File('$keys/$k.pub').readAsStringSync(),
      ].join();
      // dartgit must derive the public keys itself.
      File('$keys/id_ed25519.pub').deleteSync();
      File('$keys/id_rsa.pub').deleteSync();
      server = await Sshd.start(keys, authorized);
    });
    tearDownAll(() {
      server?.stop();
      if (server != null) Directory(keys).deleteSync(recursive: true);
    });
    setUp(() => known = '${tempDir()}/known_hosts.json');

    /// git's ssh: OpenSSH with a plain key, no prompts.
    Map<String, String> sshEnv() => {
          'GIT_SSH_COMMAND': '${_which('ssh')} -i $keys/cli_key '
              '-o IdentitiesOnly=yes -o BatchMode=yes '
              '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '
              '-o LogLevel=ERROR',
        };
    Git keyGit(String key, {String? pass}) => goldenGit(
          credentials: SshKey('$keys/$key', passphrase: pass),
          verifyHostKey: pinTo(known),
        );
    String sshUrl(String path) => 'ssh://$_user@127.0.0.1:${port()}$path';

    for (final fmt in ObjectFormat.values) {
      test('${fmt.name}: clone, push, fetch and rebase match git over ssh',
          () async {
        final root = tempDir('sshremote');
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
          final w = '$root/seed-$name';
          cli(['clone', '-q', '$root/$name', w], root);
          writeFile(w, 'n.md', '1\n2\n3\n');
          cli(['add', '-A'], w);
          cli(['commit', '-q', '-m', 'seed'], w);
          cli(['push', '-q', 'origin', 'main'], w);
        }
        final dg = keyGit('id_ed25519', pass: passphrase);
        final c = tempDir('sshclones');
        final t = Twin('$c/cli', '$c/dg');
        cli(['clone', '-q', sshUrl('$root/one.git'), t.cliDir], c,
            env: sshEnv());
        await dg.clone(sshUrl('$root/two.git'), t.dgDir);
        await t.expectSame(dg, reason: 'clone');

        t.write('n.md', '1a\n2\n3\n');
        cli(['commit', '-q', '-am', 'edit'], t.cliDir);
        await dg.commit(t.dgDir, 'edit', only: ['n.md']);
        cli(['push', '-q', 'origin', 'main'], t.cliDir, env: sshEnv());
        await dg.push(t.dgDir, 'main');
        expect(describe('$root/two.git', bare: true),
            describe('$root/one.git', bare: true));

        for (final name in ['one.git', 'two.git']) {
          final w = '$root/other-$name';
          cli(['clone', '-q', '$root/$name', w], root);
          writeFile(w, 'n.md', '1a\n2\n3b\n');
          cli(['commit', '-q', '-am', 'other'], w);
          cli(['push', '-q', 'origin', 'main'], w);
        }
        t.write('local.md', 'l\n');
        cli(['add', '-A'], t.cliDir);
        cli(['commit', '-q', '-m', 'local'], t.cliDir);
        // A second key type for the rest of the conversation.
        final rsa = keyGit('id_rsa');
        await rsa.add(t.dgDir, ['.']);
        await rsa.commit(t.dgDir, 'local');
        cli(['fetch', '-q', 'origin'], t.cliDir, env: sshEnv());
        await rsa.fetch(t.dgDir);
        cli(['rebase', '-q', 'origin/main'], t.cliDir);
        expect((await rsa.rebase(t.dgDir, 'origin/main')).ok, isTrue);
        await t.expectSame(rsa, reason: 'rebase');
        cli(['push', '-q', 'origin', 'main'], t.cliDir, env: sshEnv());
        await rsa.push(t.dgDir, 'main');
        expect(describe('$root/two.git', bare: true),
            describe('$root/one.git', bare: true));
        expectFsck('$root/two.git');
        expect(await rsa.lsRemote(sshUrl('$root/two.git')), {
          for (final l in lines(
              cli(['ls-remote', sshUrl('$root/one.git')], root, env: sshEnv())))
            l.split('\t')[1]: l.split('\t')[0],
        });
      });
    }

    test('host keys are pinned on first use and a changed key is refused',
        () async {
      final root = tempDir('pin');
      cli(['init', '-q', '--bare', 'r.git'], root);
      final g = keyGit('id_rsa');
      await g.lsRemote(sshUrl('$root/r.git'));
      final pins =
          jsonDecode(File(known).readAsStringSync()) as Map<String, dynamic>;
      expect(pins.keys, ['[127.0.0.1]:${port()}']);
      // The pin is OpenSSH's fingerprint of the host key.
      final fp = (Process.runSync(_which('ssh-keygen')!, [
        '-l',
        '-E',
        'sha256',
        '-f',
        '$keys/host_key.pub'
      ]).stdout as String)
          .split(' ')[1];
      expect(pins.values.single, fp);
      File(known).writeAsStringSync(
          jsonEncode({'[127.0.0.1]:${port()}': 'SHA256:other'}));
      await expectLater(
          g.lsRemote(sshUrl('$root/r.git')),
          throwsA(isA<GitException>().having((e) => e.message, 'message',
              contains('Host key verification failed'))));
      // Without a verifier every host is unknown, as with ssh in batch mode.
      await expectLater(
          goldenGit(credentials: SshKey('$keys/id_rsa'))
              .lsRemote(sshUrl('$root/r.git')),
          throwsA(isA<GitException>().having((e) => e.message, 'message',
              contains('Host key verification failed'))));
    });

    test('authentication errors are reported', () async {
      final root = tempDir('auth');
      cli(['init', '-q', '--bare', 'r.git'], root);
      Future<void> fails(Git g, String message) => expectLater(
          g.lsRemote(sshUrl('$root/r.git')),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', contains(message))));
      await fails(keyGit('id_ed25519'), 'passphrase');
      await fails(keyGit('id_ed25519', pass: 'wrong'), 'cannot load SSH key');
      await fails(keyGit('missing'), 'not found');
      await fails(goldenGit(verifyHostKey: pinTo(known)), 'authentication');
      final notAKey = '$keys/not-a-key';
      File(notAKey).writeAsStringSync('hello');
      await fails(
          goldenGit(credentials: SshKey(notAKey), verifyHostKey: pinTo(known)),
          'cannot load SSH key');
      await fails(
          goldenGit(
              credentials: const SshAgent(socketPath: '/nonexistent/agent'),
              verifyHostKey: pinTo(known)),
          'SSH agent');
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closed = s.port;
      await s.close();
      await expectLater(
          keyGit('id_rsa').lsRemote('ssh://$_user@127.0.0.1:$closed/x.git'),
          throwsA(isA<GitException>().having(
              (e) => e.message, 'message', contains('cannot connect'))));
      // The remote command fails: no such repository.
      await expectLater(keyGit('id_rsa').lsRemote(sshUrl('$root/missing.git')),
          throwsA(isA<GitException>()));
    });

    test('ssh agent with ed25519 and RSA keys', () async {
      final root = tempDir('agent');
      cli(['init', '-q', '--bare', 'r.git'], root);
      for (final (file, pass) in [
        ('id_ed25519', passphrase),
        ('id_rsa', null)
      ]) {
        final pair =
            SSHKeyPair.fromPem(File('$keys/$file').readAsStringSync(), pass);
        final sock = '${Directory.systemTemp.createTempSync('dga').path}/agent';
        final agent = await TestAgent.start(sock, pair);
        addTearDown(agent.close);
        final g = goldenGit(
            credentials: SshAgent(socketPath: sock),
            verifyHostKey: pinTo(known));
        final dir = '${tempDir()}/c';
        await g.clone(sshUrl('$root/r.git'), dir);
        expect(await g.isRepository(dir), isTrue);
      }
      final rsa =
          SSHKeyPair.fromPem(File('$keys/id_rsa').readAsStringSync(), null);
      for (final (keys, fault, message) in [
        (<SSHKeyPair>[], AgentFault.none, 'no keys'),
        (rsa, AgentFault.refuseList, 'refused to list keys'),
        (rsa, AgentFault.refuseSign, 'authentication failed'),
        (rsa, AgentFault.hangUp, 'SSH agent closed'),
      ]) {
        final sock = '${Directory.systemTemp.createTempSync('dga').path}/agent';
        final agent = await TestAgent.start(sock, keys, fault: fault);
        addTearDown(agent.close);
        await expectLater(
            goldenGit(
                    credentials: SshAgent(socketPath: sock),
                    verifyHostKey: pinTo(known))
                .lsRemote(sshUrl('$root/r.git')),
            throwsA(isA<GitException>()
                .having((e) => e.message, 'message', contains(message))),
            reason: '$fault');
      }
    });

    test('the local user name is used when the URL has none, like ssh',
        () async {
      final root = tempDir('nouser');
      cli(['init', '-q', '--bare', 'r.git'], root);
      final url = 'ssh://127.0.0.1:${port()}$root/r.git';
      final env = Platform.environment;
      final local = env['USER'] ?? env['USERNAME'] ?? 'git';
      if (local == _user) {
        expect(await keyGit('id_rsa').lsRemote(url), isEmpty);
      } else {
        await expectLater(
            keyGit('id_rsa').lsRemote(url),
            throwsA(isA<GitException>().having((e) => e.message, 'message',
                contains('failed for $local@127.0.0.1'))));
      }
    });

    test('a server that does not speak SSH', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(s.close);
      s.listen((c) {
        c.write('HTTP/1.0 400 Bad Request\r\n\r\n');
        c.close();
      });
      await expectLater(
          keyGit('id_rsa').lsRemote('ssh://$_user@127.0.0.1:${s.port}/x.git'),
          throwsA(isA<GitException>()));
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
