import 'dart:async';
import 'dart:io';

import 'transport.dart';

/// Runs `git-upload-pack` / `git-receive-pack` from the Git CLI on a local
/// path. Not used by [GitBackend] (mobile platforms have no git binary); it
/// exists so tests can exercise the stateful smart protocol code shared
/// with SSH without an SSH server.
class ProcessTransport implements Transport {
  ProcessTransport(this.path, {this.timeout = const Duration(minutes: 2)});

  final String path;
  final Duration timeout;

  StreamChannel _channel() => StreamChannel((service) async {
        final p = await Process.start('git', [service.substring(4), path]);
        final err = p.stderr.drain<void>();
        return StreamEndpoint(
          output: p.stdout,
          write: p.stdin.add,
          dispose: () async {
            try {
              await p.stdin.close();
            } catch (_) {}
            await err;
            await p.exitCode.timeout(const Duration(seconds: 10),
                onTimeout: () {
              p.kill();
              return -1;
            });
          },
        );
      }, timeout);

  @override
  Future<UploadSession> openUpload() => SmartUploadSession.open(_channel());

  @override
  Future<ReceiveSession> openReceive() => SmartReceiveSession.open(_channel());
}
