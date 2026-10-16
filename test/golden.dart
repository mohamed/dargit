/// Golden-reference harness: the git CLI defines the expected result.
///
/// A scenario runs twice, once through the `git` executable and once through
/// dartgit, with the same identity and the same clock, so both must produce
/// byte-identical objects (same commit ids), the same index, refs, status
/// and log, as reported by git itself.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartgit/dartgit.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const goldenName = 'Golden Tester';
const goldenEmail = 'golden@example.com';

/// 2026-01-01T00:00:00Z.
const goldenSeconds = 1767225600;

/// The clock both sides use (top-level, so it can cross into isolates).
DateTime goldenClock() =>
    DateTime.fromMillisecondsSinceEpoch(goldenSeconds * 1000, isUtc: true);

/// Environment for the git CLI: isolated config, fixed identity and dates.
final Map<String, String> goldenEnv = {
  ...gitEnv,
  'GIT_AUTHOR_NAME': goldenName,
  'GIT_AUTHOR_EMAIL': goldenEmail,
  'GIT_COMMITTER_NAME': goldenName,
  'GIT_COMMITTER_EMAIL': goldenEmail,
  'GIT_AUTHOR_DATE': '@$goldenSeconds +0000',
  'GIT_COMMITTER_DATE': '@$goldenSeconds +0000',
  'GIT_CONFIG_COUNT': '2',
  'GIT_CONFIG_KEY_0': 'init.defaultBranch',
  'GIT_CONFIG_VALUE_0': 'master',
  'GIT_CONFIG_KEY_1': 'core.quotePath',
  'GIT_CONFIG_VALUE_1': 'false',
};

/// Runs git; returns the result without failing.
ProcessResult runGit(List<String> args, String dir,
        {Map<String, String> env = const {}}) =>
    Process.runSync('git', args,
        workingDirectory: dir,
        environment: {...goldenEnv, ...env},
        stdoutEncoding: utf8);

/// Runs git and returns stdout; fails the test when git fails.
String cli(List<String> args, String dir,
    {Map<String, String> env = const {}}) {
  final r = runGit(args, dir, env: env);
  if (r.exitCode != 0) {
    fail('git ${args.join(' ')} failed (${r.exitCode}) in $dir:\n'
        '${r.stdout}\n${r.stderr}');
  }
  return r.stdout as String;
}

/// Like [runGit] but without blocking the isolate (needed when the server
/// git talks to runs in this isolate, e.g. the test HTTP server).
Future<ProcessResult> runGitAsync(List<String> args, String dir,
        {Map<String, String> env = const {}}) =>
    Process.run('git', args,
        workingDirectory: dir,
        environment: {...goldenEnv, ...env},
        stdoutEncoding: utf8);

/// Like [cli] but without blocking the isolate.
Future<String> cliAsync(List<String> args, String dir,
    {Map<String, String> env = const {}}) async {
  final r = await runGitAsync(args, dir, env: env);
  if (r.exitCode != 0) {
    fail('git ${args.join(' ')} failed (${r.exitCode}) in $dir:\n'
        '${r.stdout}\n${r.stderr}');
  }
  return r.stdout as String;
}

/// Raw bytes of `git show <rev>:<path>`, or null when git says it is absent.
Uint8List? cliShow(String dir, String rev, String path) {
  final r = Process.runSync('git', ['cat-file', 'blob', '$rev:$path'],
      workingDirectory: dir, environment: goldenEnv, stdoutEncoding: null);
  return r.exitCode == 0 ? Uint8List.fromList(r.stdout as List<int>) : null;
}

/// `git rev-parse --verify --quiet <rev>^{commit}`, null when unknown.
String? cliRevParse(String dir, String rev) {
  final r = runGit(['rev-parse', '--verify', '--quiet', '$rev^{commit}'], dir);
  return r.exitCode == 0 ? (r.stdout as String).trim() : null;
}

/// dartgit configured like [goldenEnv].
Git goldenGit({
  Credentials credentials = const NoCredentials(),
  HostKeyVerifier? verifyHostKey,
  bool useIsolates = true,
  Duration networkTimeout = const Duration(minutes: 2),
}) =>
    Git(
      credentials: credentials,
      verifyHostKey: verifyHostKey,
      authorName: goldenName,
      authorEmail: goldenEmail,
      clock: goldenClock,
      useIsolates: useIsolates,
      networkTimeout: networkTimeout,
    );

/// Everything git reports about a repository that dartgit must reproduce.
Map<String, Object?> describe(String dir, {bool bare = false}) {
  // trimRight: porcelain status lines may start with a space.
  String? opt(List<String> args) {
    final r = runGit(args, dir);
    return r.exitCode == 0 ? (r.stdout as String).trimRight() : null;
  }

  final head = opt(['rev-parse', '--verify', '--quiet', 'HEAD']);
  return {
    'HEAD': opt(['symbolic-ref', '-q', 'HEAD']) ?? head,
    'head commit': head,
    'object format': opt(['rev-parse', '--show-object-format']),
    'refs': opt(['for-each-ref', '--format=%(refname) %(objectname)']),
    'symrefs': opt([
      'for-each-ref',
      '--format=%(refname) %(symref)',
      'refs/remotes',
    ]),
    if (!bare) 'index': opt(['ls-files', '-s']),
    if (!bare)
      'status': opt([
        'status',
        '--porcelain',
        '--untracked-files=all',
        '--no-renames',
      ]),
    if (head != null) 'log': opt(['log', '--format=%H %P|%an <%ae>|%s']),
  };
}

/// Fails unless `git fsck --strict` accepts [dir].
void expectFsck(String dir) => cli(['fsck', '--strict', '--no-dangling'], dir);

/// Two working trees driven in lockstep: [cliDir] by the git CLI, [dgDir] by
/// dartgit. File edits go to both.
class Twin {
  Twin(this.cliDir, this.dgDir);

  /// Creates both repositories (`git init` vs [Git.init]).
  static Future<Twin> init(Git dg, ObjectFormat format,
      {String branch = 'main'}) async {
    final root = tempDir('twin');
    final twin = Twin('$root/cli', '$root/dg');
    Directory(twin.cliDir).createSync();
    cli(['init', '-q', '-b', branch, '--object-format=${format.name}'],
        twin.cliDir);
    await dg.init(twin.dgDir, initialBranch: branch, objectFormat: format);
    return twin;
  }

  final String cliDir;
  final String dgDir;
  List<String> get dirs => [cliDir, dgDir];

  void write(String rel, String content) {
    for (final d in dirs) {
      writeFile(d, rel, content);
    }
  }

  void writeBytes(String rel, List<int> bytes) {
    for (final d in dirs) {
      final f = File('$d/$rel')..parent.createSync(recursive: true);
      f.writeAsBytesSync(bytes);
    }
  }

  void delete(String rel) {
    for (final d in dirs) {
      final t = FileSystemEntity.typeSync('$d/$rel', followLinks: false);
      if (t == FileSystemEntityType.directory) {
        Directory('$d/$rel').deleteSync(recursive: true);
      } else if (t != FileSystemEntityType.notFound) {
        File('$d/$rel').deleteSync();
      }
    }
  }

  void rename(String from, String to) {
    for (final d in dirs) {
      File('$d/$to').parent.createSync(recursive: true);
      FileSystemEntity.typeSync('$d/$from') == FileSystemEntityType.directory
          ? Directory('$d/$from').renameSync('$d/$to')
          : File('$d/$from').renameSync('$d/$to');
    }
  }

  void chmodExec(String rel) {
    for (final d in dirs) {
      Process.runSync('chmod', ['+x', '$d/$rel']);
    }
  }

  void symlink(String rel, String target) {
    for (final d in dirs) {
      Link('$d/$rel').createSync(target, recursive: true);
    }
  }

  /// Runs `git <args>` in both trees (to set up state outside dartgit).
  void both(List<String> args) {
    for (final d in dirs) {
      cli(args, d);
    }
  }

  /// git's view of both repositories must be identical, dartgit's status
  /// must equal git's, and the dartgit repository must pass fsck.
  Future<void> expectSame(Git dg, {String? reason}) async {
    final want = describe(cliDir), got = describe(dgDir);
    for (final k in want.keys) {
      expect(got[k], want[k],
          reason: '$k differs${reason == null ? '' : ' ($reason)'}');
    }
    expect([for (final e in await dg.status(dgDir)) '$e'],
        _lines(want['status'] as String?),
        reason: 'dartgit status vs git status');
    if (want['head commit'] != null) expectFsck(dgDir);
  }
}

List<String> _lines(String? s) =>
    s == null || s.isEmpty ? const [] : s.split('\n');

/// Lines of git output, empty output giving an empty list.
List<String> lines(String s) => _lines(s.trimRight());

/// A repository with one commit made by git.
String gitRepo(ObjectFormat fmt,
    {Map<String, String> files = const {
      'a.md': 'a\n',
    }}) {
  final d = tempDir('edge');
  cli(['init', '-q', '-b', 'main', '--object-format=${fmt.name}'], d);
  files.forEach((p, c) => writeFile(d, p, c));
  cli(['add', '-A'], d);
  cli(['commit', '-q', '-m', 'base'], d);
  return d;
}

/// `git <args>` with [input] on stdin; returns stdout bytes.
Future<Uint8List> cliBytes(List<String> args, String dir,
    {List<int> input = const []}) async {
  final p = await Process.start('git', args,
      workingDirectory: dir, environment: goldenEnv);
  p.stdin.add(input);
  await p.stdin.close();
  final out = BytesBuilder(copy: false);
  final err = p.stderr.transform(utf8.decoder).join();
  await p.stdout.forEach(out.add);
  if (await p.exitCode != 0) fail('git ${args.join(' ')}: ${await err}');
  return out.takeBytes();
}
