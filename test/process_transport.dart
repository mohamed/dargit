import 'dart:async';
import 'dart:io';

import 'package:dargit/src/transport/transport.dart';

/// Runs `git-upload-pack` / `git-receive-pack` from the Git CLI on a local
/// path. Not used by [Git] (mobile platforms have no git binary); it
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
            await p.exitCode; // git exits once its stdin is closed
          },
        );
      }, timeout);

  @override
  Future<UploadSession> openUpload() => SmartUploadSession.open(_channel());

  @override
  Future<ReceiveSession> openReceive() => SmartReceiveSession.open(_channel());
}
