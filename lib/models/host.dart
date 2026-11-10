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
  });

  final String id;
  String label;
  String hostname;
  int port;
  String username;
  AuthMethod auth;

  String get displayName => label.trim().isEmpty ? hostname : label;
  String get address => '$username@$hostname${port == 22 ? '' : ':$port'}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hostname': hostname,
        'port': port,
        'username': username,
        'auth': auth.name,
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
      );
}

class HostSecrets {
  const HostSecrets({this.password, this.privateKey, this.passphrase});
  final String? password;
  final String? privateKey;
  final String? passphrase;
}
