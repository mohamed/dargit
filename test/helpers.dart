import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

final bool hasGit = () {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

/// Reason to skip interop tests, or null when the git CLI is available.
final String? skipNoGit = hasGit ? null : 'git CLI not installed';

final Map<String, String> gitEnv = {
  'GIT_AUTHOR_NAME': 'CLI',
  'GIT_AUTHOR_EMAIL': 'cli@example.com',
  'GIT_COMMITTER_NAME': 'CLI',
  'GIT_COMMITTER_EMAIL': 'cli@example.com',
  'GIT_CONFIG_NOSYSTEM': '1',
  'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
};

/// Runs the real git CLI and returns stdout; fails the test on error.
String git(List<String> args, {required String cwd}) {
  final r =
      Process.runSync('git', args, workingDirectory: cwd, environment: gitEnv);
  if (r.exitCode != 0) {
    fail(
        'git ${args.join(' ')} failed (${r.exitCode}):\n${r.stdout}\n${r.stderr}');
  }
  return r.stdout as String;
}

/// A fresh temporary directory deleted after the test.
String tempDir([String prefix = 'dartgit']) {
  final d = Directory.systemTemp.createTempSync('${prefix}_');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d.resolveSymbolicLinksSync();
}

void writeFile(String dir, String rel, String content) {
  final f = File('$dir/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

String readFile(String dir, String rel) => File('$dir/$rel').readAsStringSync();

/// Runs `git pack-objects --stdout` for the given object list.
Future<Uint8List> gitPackObjects(String dir, String objectList,
    {bool ofsDelta = true}) async {
  final p = await Process.start('git',
      ['pack-objects', '-q', '--stdout', if (ofsDelta) '--delta-base-offset'],
      workingDirectory: dir, environment: gitEnv);
  p.stdin.write(objectList);
  await p.stdin.close();
  final out = BytesBuilder();
  final err = p.stderr.drain<void>();
  await p.stdout.forEach(out.add);
  await err;
  expect(await p.exitCode, 0);
  return out.takeBytes();
}
