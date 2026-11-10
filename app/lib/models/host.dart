enum AuthMethod { password, key }

/// Non-secret connection info. Passwords / private keys live in secure storage.
class Host {
  Host({
    required this.id,
    required this.label,
    required this.hostname,
    this.port = 22,
    required this.username,
    this.auth = AuthMethod.password,
    this.keyId,
  });

  final String id;
  String label;
  String hostname;
  int port;
  String username;
  AuthMethod auth;

  /// Saved key (see SshKey) used when [auth] is [AuthMethod.key].
  String? keyId;

  String get displayName => label.trim().isEmpty ? hostname : label;
  String get address => '$username@$hostname${port == 22 ? '' : ':$port'}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hostname': hostname,
        'port': port,
        'username': username,
        'auth': auth.name,
        if (keyId != null) 'keyId': keyId,
      };

  factory Host.fromJson(Map<String, dynamic> j) => Host(
        id: j['id'] as String,
        label: (j['label'] ?? '') as String,
        hostname: j['hostname'] as String,
        port: (j['port'] ?? 22) as int,
        username: j['username'] as String,
        auth: AuthMethod.values.firstWhere(
          (a) => a.name == j['auth'],
          orElse: () => AuthMethod.password,
        ),
        keyId: j['keyId'] as String?,
      );
}

class HostSecrets {
  const HostSecrets({this.password});
  final String? password;
}

/// Private key material read from secure storage.
class KeySecrets {
  const KeySecrets({required this.pem, this.passphrase});
  final String pem;
  final String? passphrase;
}
