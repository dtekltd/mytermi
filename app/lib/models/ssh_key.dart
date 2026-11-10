import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

/// A saved private key (metadata only; the PEM + passphrase live in secure storage).
class SshKey {
  SshKey({
    required this.id,
    required this.label,
    required this.type,
    required this.publicKey,
    required this.fingerprint,
    required this.createdAt,
  });

  final String id;
  String label;

  /// e.g. `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`.
  final String type;

  /// One line for `authorized_keys`: `type base64 label`.
  final String publicKey;

  /// `SHA256:...`, same format as `ssh-keygen -lf`.
  final String fingerprint;
  final DateTime createdAt;

  /// Short name for the type, for chips / subtitles.
  String get typeLabel => switch (type) {
        'ssh-ed25519' => 'ED25519',
        'ssh-rsa' || 'rsa-sha2-256' || 'rsa-sha2-512' => 'RSA',
        final t when t.startsWith('ecdsa') => 'ECDSA',
        final t => t,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'type': type,
        'publicKey': publicKey,
        'fingerprint': fingerprint,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory SshKey.fromJson(Map<String, dynamic> j) => SshKey(
        id: j['id'] as String,
        label: (j['label'] ?? '') as String,
        type: (j['type'] ?? '') as String,
        publicKey: (j['publicKey'] ?? '') as String,
        fingerprint: (j['fingerprint'] ?? '') as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch((j['createdAt'] ?? 0) as int),
      );
}

/// Result of parsing a PEM: public info, or an error message to show.
class ParsedKey {
  ParsedKey({required this.type, required this.publicBlob});
  final String type;
  final Uint8List publicBlob;

  String publicLine(String comment) {
    final c = comment.trim().replaceAll(RegExp(r'\s+'), '_');
    return '$type ${base64.encode(publicBlob)}${c.isEmpty ? '' : ' $c'}';
  }

  String get fingerprint =>
      'SHA256:${base64.encode(sha256.convert(publicBlob).bytes).replaceAll('=', '')}';
}

/// Thrown by [parsePrivateKey] with a user-facing (Vietnamese) message.
class KeyParseException implements Exception {
  KeyParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parses an OpenSSH / PEM private key. Throws [KeyParseException].
ParsedKey parsePrivateKey(String pem, String? passphrase) {
  final text = pem.trim();
  if (text.isEmpty) throw KeyParseException('Dán private key vào đây');
  final pp = (passphrase == null || passphrase.isEmpty) ? null : passphrase;
  try {
    if (SSHKeyPair.isEncryptedPem(text) && pp == null) {
      throw KeyParseException('Key đã mã hoá, nhập passphrase bên dưới');
    }
    final pairs = SSHKeyPair.fromPem(text, pp);
    if (pairs.isEmpty) throw KeyParseException('Không đọc được key');
    final pair = pairs.first;
    return ParsedKey(type: pair.name, publicBlob: pair.toPublicKey().encode());
  } on KeyParseException {
    rethrow;
  } catch (_) {
    throw KeyParseException(pp == null ? 'Key không hợp lệ' : 'Key không hợp lệ hoặc sai passphrase');
  }
}

/// Generates a new Ed25519 key, returned as an OpenSSH PEM.
String generateEd25519Pem(String comment) {
  final sk = ed25519.SigningKey.generate();
  final pair = OpenSSHEd25519KeyPair(
    Uint8List.fromList(sk.verifyKey.asTypedList),
    Uint8List.fromList(sk.asTypedList), // 64 bytes: seed + public key
    comment,
  );
  return pair.toPem();
}
