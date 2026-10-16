/// How to authenticate to a remote, the way `git` gets it from a credential
/// helper (HTTPS) or from `ssh` (SSH).
sealed class Credentials {
  const Credentials();
}

/// No credentials: anonymous HTTPS, local paths, or credentials embedded in
/// the URL (`https://user:token@host/repo`).
class NoCredentials extends Credentials {
  const NoCredentials();
}

/// HTTP Basic credentials (user name and password or token).
class UserPassword extends Credentials {
  const UserPassword(this.username, this.password);
  final String username;
  final String password;
}

/// An OpenSSH or PEM private key file (like `ssh -i`). The public key is
/// derived from the private key; no `.pub` file is needed.
class SshKey extends Credentials {
  const SshKey(this.path, {this.passphrase});
  final String path;
  final String? passphrase;
}

/// Keys held by an ssh-agent (Linux and macOS). [socketPath] defaults to
/// `SSH_AUTH_SOCK`.
class SshAgent extends Credentials {
  const SshAgent({this.socketPath});
  final String? socketPath;
}

/// Decides whether to trust an SSH host key, like `ssh` consulting
/// `known_hosts`. [host] is `host`, or `[host]:port` for a port other than
/// 22; [fingerprint] is OpenSSH's `SHA256:<base64>` form (as printed by
/// `ssh-keygen -lf`). Must be a top-level/static function or a closure over
/// sendable values, because operations run in a background isolate.
typedef HostKeyVerifier = bool Function(String host, String fingerprint);
