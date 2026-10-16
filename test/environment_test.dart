// Failures that only some environments can produce: files the user may
// not read, directories even root may not change, a system without
// `chmod`. Each test skips itself elsewhere; `tool/coverage.sh` runs them
// in those environments. git, run in the same environment, is the
// reference.
import 'dart:io';

import 'package:dartgit/dartgit.dart';
import 'package:test/test.dart';

import 'golden.dart';
import 'helpers.dart';

bool _runs(String exe, List<String> args) {
  try {
    return Process.runSync(exe, args).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Whether [exe] is on PATH (looked up, not run).
bool _installed(String exe) => (Platform.environment['PATH'] ?? '')
    .split(':')
    .any((dir) => dir.isNotEmpty && File('$dir/$exe').existsSync());

final bool _isRoot = () {
  final status = File('/proc/self/status');
  if (status.existsSync()) {
    return RegExp(r'^Uid:\s+0\s', multiLine: true)
        .hasMatch(status.readAsStringSync());
  }
  return (Process.runSync('id', ['-u']).stdout as String).trim() == '0';
}();

/// `chmod` on a path, failing the test when it fails.
void _chmod(String mode, String path) {
  final r = Process.runSync('chmod', [mode, path]);
  if (r.exitCode != 0) fail('chmod $mode $path: ${r.stderr}');
}

Future<void> expectStatusLikeGit(Git dg, String dir) async => expect(
    [for (final e in await dg.status(dir)) '$e'],
    lines(cli(
        ['status', '--porcelain', '--untracked-files=all', '--no-renames'],
        dir)));

/// Why the chattr test cannot run here, or null.
final String? _noChattr = () {
  if (!hasGit) return 'git CLI not installed';
  final probe = Directory.systemTemp.createTempSync('chattr_');
  final ok = _runs('chattr', ['+a', probe.path]);
  _runs('chattr', ['-a', probe.path]);
  probe.deleteSync();
  return ok ? null : 'needs chattr +a (root, ext4)';
}();

final String? _noUnreadable = !hasGit
    ? 'git CLI not installed'
    : _isRoot
        ? 'root can read everything'
        : null;

final String? _noMissingChmod = !hasGit
    ? 'git CLI not installed'
    : _installed('chmod')
        ? 'chmod is installed'
        : null;

/// [body], skipped for [reason] at run time, so that `--run-skipped`
/// (used for the SSH tests) does not force it into the wrong environment.
Future<void> Function() _onlyIf(String? reason, Future<void> Function() body) =>
    () async {
      if (reason != null) {
        markTestSkipped(reason);
        return;
      }
      await body();
    };

void main() {
  final dg = goldenGit();

  test(
      'a failed clone into a directory nobody can empty',
      _onlyIf(_noChattr, () async {
        final remote = '${tempDir('remote')}/r.git';
        cli(['init', '-q', '--bare', remote], Directory.systemTemp.path);
        // Append-only: entries can be created but not removed.
        final dir = tempDir('appendonly');
        expect(_runs('chattr', ['+a', dir]), isTrue);
        addTearDown(() => _runs('chattr', ['-a', dir]));
        expect(
            runGit(['clone', '-b', 'nope', remote, '$dir/cli'], dir).exitCode,
            isNot(0));
        // The clone's own error is reported, not the failed clean-up.
        Directory('$dir/dg').createSync();
        expect(_runs('chattr', ['+a', '$dir/dg']), isTrue);
        addTearDown(() => _runs('chattr', ['-a', '$dir/dg']));
        await expectLater(
            dg.clone(remote, '$dir/dg', branch: 'nope'),
            throwsA(isA<GitException>().having(
                (e) => e.message, 'message', contains('Remote branch nope'))));
      }));

  group('unreadable files and directories', () {
    test(
        'are skipped by status, as git skips them',
        _onlyIf(_noUnreadable, () async {
          final d = gitRepo(ObjectFormat.sha1);
          writeFile(d, '.gitignore', 'ignored\n');
          writeFile(d, 'ignored', '');
          writeFile(d, 'secret/file', '');
          _chmod('000', '$d/.gitignore');
          _chmod('000', '$d/secret');
          addTearDown(() {
            _chmod('755', '$d/secret');
            _chmod('644', '$d/.gitignore');
          });
          await expectStatusLikeGit(dg, d);
        }));

    test(
        'tracked files in a directory that cannot be listed are still seen',
        _onlyIf(_noUnreadable, () async {
          final d = gitRepo(ObjectFormat.sha1,
              files: {'locked/file.md': 'f\n', 'locked/gone.md': 'g\n'});
          Link('$d/locked/link').createSync('file.md');
          Directory('$d/locked/sub').createSync(); // a submodule's place
          cli([
            'update-index',
            '--add',
            '--cacheinfo',
            '160000,${cliRevParse(d, 'HEAD')},locked/sub'
          ], d);
          cli(['add', '-A'], d);
          cli(['commit', '-q', '-m', 'locked'], d);
          File('$d/locked/gone.md').deleteSync();
          writeFile(d, 'locked/file.md', 'changed\n');
          _chmod('100', '$d/locked'); // search only: no listing
          addTearDown(() => _chmod('755', '$d/locked'));
          await expectStatusLikeGit(dg, d);
        }));

    test(
        'an emptied directory is removed even when unreadable',
        _onlyIf(_noUnreadable, () async {
          final t = await Twin.init(dg, ObjectFormat.sha1);
          t.write('a.md', 'a\n');
          t.write('dir/b.md', 'b\n');
          cli(['add', '-A'], t.cliDir);
          cli(['commit', '-q', '-m', 'one'], t.cliDir);
          await dg.add(t.dgDir, ['.']);
          await dg.commit(t.dgDir, 'one');
          t.delete('dir');
          cli(['commit', '-q', '-am', 'two'], t.cliDir);
          await dg.commit(t.dgDir, 'two', only: ['dir']);
          final two = cliRevParse(t.cliDir, 'HEAD')!;
          cli(['reset', '-q', '--hard', 'HEAD~1'], t.cliDir);
          await dg.resetHard(t.dgDir, cliRevParse(t.cliDir, 'HEAD')!);
          for (final d in t.dirs) {
            _chmod('300', '$d/dir'); // write and search, no read
          }
          addTearDown(() {
            for (final d in t.dirs) {
              if (Directory('$d/dir').existsSync()) _chmod('755', '$d/dir');
            }
          });
          cli(['reset', '-q', '--hard', two], t.cliDir);
          await dg.resetHard(t.dgDir, two);
          await t.expectSame(dg);
          for (final d in t.dirs) {
            expect(Directory('$d/dir').existsSync(), isFalse);
          }
        }));
  });

  test(
      'without chmod, executables are checked out as plain files',
      _onlyIf(_noMissingChmod, () async {
        final d = gitRepo(ObjectFormat.sha1, files: {'run.sh': 'echo\n'});
        cli(['update-index', '--chmod=+x', 'run.sh'], d);
        cli(['commit', '-q', '-m', 'exec'], d);
        final root = tempDir('nochmod');
        cli(['clone', '-q', d, '$root/cli'], root);
        await dg.clone(d, '$root/dg');
        // git sets the bit itself (chmod(2)); dartgit cannot without chmod(1):
        // git then reports the mode change.
        expect(File('$root/dg/run.sh').statSync().mode & 0x40, 0);
        expect(
            [for (final e in await dg.status('$root/dg')) '$e'], [' M run.sh']);
        expect(cli(['status', '--porcelain'], '$root/dg'), ' M run.sh\n');
      }));
}
