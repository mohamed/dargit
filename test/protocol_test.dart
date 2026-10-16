// The smart protocol client talking to git's own upload-pack and
// receive-pack (`--stateless-rpc`, as git http-backend runs them), with
// the capabilities git advertises narrowed to exercise older servers, plus
// scripted servers for answers git never gives.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartgit/dartgit.dart';
import 'package:dartgit/src/objects.dart';
import 'package:dartgit/src/pack.dart';
import 'package:dartgit/src/transport/local.dart';
import 'package:dartgit/src/transport/pktline.dart';
import 'package:dartgit/src/transport/transport.dart';
import 'package:dartgit/src/util.dart' show GitError;
import 'package:test/test.dart';

import 'golden.dart';
import 'helpers.dart';

/// Splits pkt-lines up to the first flush.
List<String> _pktLines(Uint8List b) {
  final out = <String>[];
  var p = 0;
  while (p + 4 <= b.length) {
    final len = int.parse(ascii.decode(b.sublist(p, p + 4)), radix: 16);
    if (len == 0) break;
    out.add(utf8.decode(b.sublist(p + 4, p + len)));
    p += len;
  }
  return out;
}

/// [bytes] as a stream of small chunks, as a network delivers them.
Stream<List<int>> chunked(List<int> bytes) => Stream.fromIterable([
      for (var i = 0; i < bytes.length; i += 1000)
        bytes.sublist(i, i + 1000 > bytes.length ? bytes.length : i + 1000),
    ]);

/// A [SmartChannel] running git's service in [dir] for each request, with
/// the advertised capabilities filtered through [caps].
class GitChannel implements SmartChannel {
  GitChannel(this.dir, {this.caps = _all});
  final String dir;
  final Iterable<String> Function(List<String>) caps;
  var closed = false;

  static Iterable<String> _all(List<String> c) => c;

  @override
  Future<PktReader> advertise(String service) async {
    final raw = await cliBytes(
        [service.substring(4), '--stateless-rpc', '--advertise-refs', dir],
        dir);
    final lines = _pktLines(raw);
    final out = BytesBuilder();
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i];
      if (i == 0) {
        final nul = l.indexOf('\u0000');
        final c = l.substring(nul + 1).trim().split(' ');
        l = '${l.substring(0, nul)}\u0000${caps(c).join(' ')}\n';
      }
      out.add(pkt(l));
    }
    out.add(flushPkt);
    return PktReader(chunked(out.takeBytes()));
  }

  @override
  Future<PktReader> request(String service, Uint8List body) async =>
      PktReader(chunked(await cliBytes(
          [service.substring(4), '--stateless-rpc', dir], dir,
          input: body)));

  @override
  Future<void> close() async => closed = true;
}

/// Git's advertisement, then a scripted [response].
class ScriptedChannel extends GitChannel {
  ScriptedChannel(super.dir, this.response, {super.caps});
  final List<int> response;

  @override
  Future<PktReader> request(String service, Uint8List body) async =>
      PktReader(chunked(response));
}

Iterable<String> Function(List<String>) without(List<String> drop) =>
    (c) => c.where((x) => !drop.any(x.startsWith));

Matcher gitError(String text) => throwsA(
    isA<GitError>().having((e) => e.message, 'message', contains(text)));

void main() {
  for (final fmt in ObjectFormat.values) {
    group('${fmt.name}:', skip: skipNoGit, () {
      late String remote;
      late String head;
      setUp(() {
        final d = gitRepo(fmt);
        writeFile(d, 'b.md', 'b\n');
        cli(['add', '-A'], d);
        cli(['commit', '-q', '-m', 'second'], d);
        remote = '${tempDir('proto')}/r.git';
        cli(['clone', '-q', '--bare', d, remote], d);
        head = cliRevParse(remote, 'HEAD')!;
      });

      Future<void> expectFetches(GitChannel ch) async {
        final s = await SmartUploadSession.open(ch);
        expect(s.head, 'refs/heads/main');
        expect(s.format, fmt);
        expect(s.refs, {'refs/heads/main': head});
        final odb = tempDir('odb');
        storePack(ObjectDatabase(odb, fmt), await s.fetchPack([head], []));
        expect(ObjectDatabase(odb, fmt).readCommit(head).message, 'second\n');
        await s.close();
        expect(ch.closed, isTrue);
      }

      test('fetch from a server without symref, side-band or no-progress',
          () async {
        // HEAD is guessed from the ids; the pack comes without side-band.
        await expectFetches(GitChannel(remote,
            caps: without(['symref', 'side-band', 'no-progress'])));
      });

      test('fetch with side-band (not 64k) and progress messages', () async {
        await expectFetches(GitChannel(remote,
            caps: without(['side-band-64k', 'no-progress'])));
      });

      test('fetch answers git never gives are errors', () async {
        Future<void> fails(List<int> response, String text,
            {List<String> drop = const []}) async {
          final s = await SmartUploadSession.open(
              ScriptedChannel(remote, response, caps: without(drop)));
          await expectLater(s.fetchPack([head], []), gitError(text));
        }

        await fails([...pkt('NAK\n'), ...pkt('what\n')], 'unexpected "what"');
        await fails([
          ...pkt('NAK\n'),
          ...pktBytes([3, ...utf8.encode('no')])
        ], 'remote: no');
        await fails([
          ...pkt('NAK\n'),
          ...pktBytes([1, 1]),
          ...pktBytes([9]),
        ], 'bad side-band 9');
        await fails(ascii.encode('00'), 'unexpected end of stream');
        await fails(ascii.encode('0010NAK'), 'unexpected end of stream');
        await fails([], 'unexpected end of stream', drop: ['side-band']);
        await fails(ascii.encode('zzzz'), 'bad pkt-line header');
        await fails(pkt('ERR denied\n'), 'remote error: denied');
        final s = await SmartUploadSession.open(GitChannel(remote));
        await expectLater(s.fetchPack([], []), gitError('nothing to fetch'));
      });

      test('push results reported by git receive-pack', () async {
        final first = cliRevParse(remote, 'HEAD~1')!;
        final empty = buildPack(const [], fmt);
        Future<SmartReceiveSession> open([List<String> drop = const []]) =>
            SmartReceiveSession.open(GitChannel(remote, caps: without(drop)));

        // git refuses a rewind when told to, with "ng".
        cli(['config', 'receive.denyNonFastForwards', 'true'], remote);
        await expectLater(
            (await open())
                .push([RefUpdate('refs/heads/main', head, first)], empty),
            gitError('push rejected: refs/heads/main'));
        // An unreadable pack fails to unpack.
        await expectLater(
            (await open()).push([RefUpdate('refs/heads/x', fmt.zeroId, head)],
                Uint8List.fromList(utf8.encode('garbage'))),
            gitError('remote failed to unpack'));
        // Deleting needs delete-refs.
        await expectLater(
            (await open(['delete-refs']))
                .push([RefUpdate('refs/heads/main', head, fmt.zeroId)], null),
            gitError('does not support deleting'));
        // With it, git deletes the ref.
        cli(['branch', 'gone', 'main'], remote);
        await (await open())
            .push([RefUpdate('refs/heads/gone', head, fmt.zeroId)], null);
        expect(cliRevParse(remote, 'gone'), isNull);
        await (await open()).push(const [], null);
        // A server that answers nonsense.
        final s =
            await SmartReceiveSession.open(ScriptedChannel(remote, flushPkt));
        await expectLater(
            s.push([RefUpdate('refs/heads/y', fmt.zeroId, head)], empty),
            gitError('bad push status'));
      });

      test('local receive refuses what git receive-pack refuses', () async {
        final s = await LocalTransport(remote).openReceive();
        final first = cliRevParse(remote, 'HEAD~1')!;
        await expectLater(
            s.push([RefUpdate('refs/heads/main', first, head)], null),
            gitError('stale info'));
        final unknown = 'b' * fmt.hexLength;
        await expectLater(
            s.push([RefUpdate('refs/heads/n', fmt.zeroId, unknown)], null),
            gitError('missing object'));
        // A commit whose tree is missing (git hash-object --literally).
        File('$remote/c').writeAsStringSync(
            'tree $unknown\nauthor a <a> 0 +0000\ncommitter a <a> 0 +0000\n\nx\n');
        final broken = cli(
                ['hash-object', '-t', 'commit', '-w', '--literally', 'c'],
                remote)
            .trim();
        await expectLater(
            s.push([RefUpdate('refs/heads/n', fmt.zeroId, broken)], null),
            gitError('missing object $unknown'));
        cli(['branch', 'gone', 'main'], remote);
        await s.push([RefUpdate('refs/heads/gone', head, fmt.zeroId)], null);
        expect(cliRevParse(remote, 'gone'), isNull);
        expectFsck(remote);
        await s.close();
      });

      test('push refspecs resolve like git push', () async {
        final dg = goldenGit();
        final root = tempDir('refspec');
        final clis = '$root/cli', dgs = '$root/dg';
        cli(['clone', '-q', remote, clis], root);
        await dg.clone(remote, dgs);
        for (final d in [clis, dgs]) {
          cli(['checkout', '-q', '-b', 'topic'], d);
          writeFile(d, 't.md', 't\n');
          cli(['add', '-A'], d);
          cli(['commit', '-q', '-m', 'topic'], d);
        }
        // `HEAD` and `refs/heads/<branch>` name the branch to push.
        cli(['push', '-q', 'origin', 'HEAD'], clis);
        final topic = cliRevParse(remote, 'topic')!;
        cli(['push', '-q', 'origin', ':topic'], clis);
        await dg.push(dgs, 'HEAD');
        expect(cliRevParse(remote, 'topic'), topic);
        cli(['push', '-q', 'origin', ':topic'], clis);
        await dg.push(dgs, 'refs/heads/topic');
        expect(cliRevParse(remote, 'topic'), topic);
        // No destination for a commit, as in git.
        final first = cliRevParse(clis, 'HEAD~1')!;
        expect(runGit(['push', 'origin', first], clis).exitCode, isNot(0));
        await expectLater(
            dg.push(dgs, first),
            throwsA(isA<GitException>()
                .having((e) => e.message, 'message', contains('destination'))));
        // dartgit pushes branches only.
        await expectLater(
            dg.push(dgs, 'HEAD:refs/tags/t'),
            throwsA(isA<GitException>().having(
                (e) => e.message, 'message', contains('only branches'))));
        // A rewind of a branch we have fetched is non-fast-forward.
        cli(['reset', '-q', '--hard', 'HEAD~1'], clis);
        await dg.resetHard(dgs, first);
        expect(runGit(['push', 'origin', 'topic'], clis).stderr,
            contains('non-fast-forward'));
        await expectLater(
            dg.push(dgs, 'topic'),
            throwsA(isA<GitException>().having(
                (e) => e.message, 'message', contains('non-fast-forward'))));
      });

      test('a failed clone leaves an existing empty directory empty', () async {
        final dg = goldenGit();
        final dir = tempDir('emptydir');
        expect(runGit(['clone', '-b', 'nope', remote, dir], dir).exitCode,
            isNot(0));
        expect(Directory(dir).listSync(), isEmpty);
        await expectLater(dg.clone(remote, dir, branch: 'nope'),
            throwsA(isA<GitException>()));
        expect(Directory(dir).listSync(), isEmpty);
        // A destination below a file cannot be created.
        File('$dir/file').writeAsStringSync('x');
        await expectLater(
            dg.clone(remote, '$dir/file/sub'), throwsA(isA<GitException>()));
      });
    });
  }

  group('errors from the network and from corrupt data', () {
    Future<int> serve(void Function(Socket) handle) async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(s.close);
      s.listen(handle);
      return s.port;
    }

    test('TLS to a server that does not speak it', () async {
      final port = await serve((c) {
        c.write('HTTP/1.0 400 Bad Request\r\n\r\n');
        c.close();
      });
      await expectLater(
          goldenGit().lsRemote('https://127.0.0.1:$port/r.git/'),
          throwsA(isA<GitException>()
              .having((e) => e.message, 'message', startsWith('TLS error'))));
    });

    test('HTTP garbage', () async {
      final port = await serve((c) {
        c.write('NOT HTTP AT ALL\r\n\r\n');
        c.close();
      });
      await expectLater(goldenGit().lsRemote('http://127.0.0.1:$port/r.git/'),
          throwsA(isA<GitException>()));
    });

    test('a corrupt loose object', skip: skipNoGit, () async {
      final d = gitRepo(ObjectFormat.sha1);
      final id = cliRevParse(d, 'HEAD')!;
      final f =
          File('$d/.git/objects/${id.substring(0, 2)}/${id.substring(2)}');
      f
        ..setLastModifiedSync(DateTime.now())
        ..writeAsBytesSync([0x78, 0x9c, 0xff, 0xff, 0xff]);
      expect(runGit(['log'], d).exitCode, isNot(0));
      await expectLater(
          goldenGit().log(d),
          throwsA(isA<GitException>().having(
              (e) => e.message, 'message', startsWith('corrupt data'))));
    });
  });
}
