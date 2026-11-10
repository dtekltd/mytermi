import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// End-to-end encryption for synced data. See docs/encryption.md.
///
/// * Vault key (VK): 32 random bytes, generated on the first device.
/// * Vault password → Argon2id → KEK; VK sealed with XChaCha20-Poly1305.
/// * Recovery key: 20 random bytes shown once as Crockford base32;
///   HKDF-SHA256 → KEK; VK sealed again with it.
/// * Each item: XChaCha20-Poly1305 with VK, AAD binds the item type and id.
///
/// Sealed format: nonce (24 bytes) || ciphertext || tag (16 bytes).
class VaultCrypto {
  VaultCrypto({this.kdf = KdfParams.standard});

  final KdfParams kdf;
  static final _aead = Xchacha20.poly1305Aead();
  static const _vkAad = 'mytermi-vault-key-v1';

  static Uint8List randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  // ---- key derivation ----

  /// Argon2id runs in a background isolate (~1s on a phone).
  static Future<Uint8List> deriveFromPassword(String password, Uint8List salt, KdfParams p) {
    return Isolate.run(() async {
      final argon = Argon2id(parallelism: p.p, memory: p.m, iterations: p.t, hashLength: 32);
      final key = await argon.deriveKeyFromPassword(password: password, nonce: salt);
      return Uint8List.fromList(await key.extractBytes());
    });
  }

  static Future<Uint8List> deriveFromRecovery(Uint8List recovery) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(recovery),
      nonce: utf8.encode('mytermi-recovery-salt-v1'),
      info: utf8.encode('mytermi-recovery-v1'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  // ---- sealing ----

  static Future<Uint8List> seal(Uint8List key, List<int> plain, String aad) async {
    final nonce = randomBytes(24);
    final box = await _aead.encrypt(plain, secretKey: SecretKey(key), nonce: nonce, aad: utf8.encode(aad));
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Throws [VaultDecryptException] on a wrong key or tampered data.
  static Future<Uint8List> open(Uint8List key, Uint8List sealed, String aad) async {
    if (sealed.length < 24 + 16) throw const VaultDecryptException();
    final box = SecretBox(
      sealed.sublist(24, sealed.length - 16),
      nonce: sealed.sublist(0, 24),
      mac: Mac(sealed.sublist(sealed.length - 16)),
    );
    try {
      return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(key), aad: utf8.encode(aad)));
    } on SecretBoxAuthenticationError {
      throw const VaultDecryptException();
    }
  }

  // ---- vault setup / unlock ----

  /// Creates a new vault: returns what to upload plus the secrets to keep.
  Future<NewVault> create(String password) async {
    final vk = randomBytes(32);
    final salt = randomBytes(16);
    final recovery = randomBytes(20);
    final kek = await deriveFromPassword(password, salt, kdf);
    final rkek = await deriveFromRecovery(recovery);
    return NewVault(
      vaultKey: vk,
      recoveryKey: RecoveryKey.format(recovery),
      envelope: VaultEnvelope(
        kdf: kdf,
        salt: salt,
        wrappedKey: await seal(kek, vk, _vkAad),
        recoveryWrappedKey: await seal(rkek, vk, _vkAad),
      ),
    );
  }

  /// Returns the vault key, or throws [VaultDecryptException] (wrong password).
  static Future<Uint8List> unlockWithPassword(VaultEnvelope env, String password) async {
    final kek = await deriveFromPassword(password, env.salt, env.kdf);
    return open(kek, env.wrappedKey, _vkAad);
  }

  /// Throws [FormatException] (malformed) or [VaultDecryptException] (wrong key).
  static Future<Uint8List> unlockWithRecovery(VaultEnvelope env, String recoveryKey) async {
    final rkek = await deriveFromRecovery(RecoveryKey.parse(recoveryKey));
    return open(rkek, env.recoveryWrappedKey, _vkAad);
  }

  /// New password for an existing vault key (data stays as is). The recovery
  /// wrapping is reused unless [newRecovery] is given.
  Future<VaultEnvelope> rewrap(Uint8List vk, String newPassword, VaultEnvelope old, {Uint8List? newRecovery}) async {
    final salt = randomBytes(16);
    final kek = await deriveFromPassword(newPassword, salt, kdf);
    return VaultEnvelope(
      kdf: kdf,
      salt: salt,
      wrappedKey: await seal(kek, vk, _vkAad),
      recoveryWrappedKey: newRecovery == null
          ? old.recoveryWrappedKey
          : await seal(await deriveFromRecovery(newRecovery), vk, _vkAad),
    );
  }

  // ---- items ----

  static String itemAad(String type, String id) => 'mytermi-item-v1:$type:$id';

  static Future<Uint8List> encryptItem(Uint8List vk, String type, String id, Map<String, dynamic> payload) =>
      seal(vk, utf8.encode(jsonEncode(payload)), itemAad(type, id));

  static Future<Map<String, dynamic>> decryptItem(Uint8List vk, String type, String id, Uint8List data) async =>
      jsonDecode(utf8.decode(await open(vk, data, itemAad(type, id)))) as Map<String, dynamic>;
}

class VaultDecryptException implements Exception {
  const VaultDecryptException();
  @override
  String toString() => 'wrong key or corrupted data';
}

class KdfParams {
  const KdfParams({required this.m, required this.t, required this.p});

  /// Argon2id, 64 MiB, 3 passes (OWASP-recommended range).
  static const standard = KdfParams(m: 65536, t: 3, p: 1);

  final int m; // memory in KiB
  final int t;
  final int p;

  Map<String, dynamic> toJson() => {'alg': 'argon2id', 'm': m, 't': t, 'p': p};

  factory KdfParams.fromJson(Map<String, dynamic> j) {
    if (j['alg'] != 'argon2id') throw FormatException('unsupported kdf ${j['alg']}');
    return KdfParams(m: j['m'] as int, t: j['t'] as int, p: (j['p'] ?? 1) as int);
  }
}

/// What the server stores (all opaque to it).
class VaultEnvelope {
  const VaultEnvelope({
    required this.kdf,
    required this.salt,
    required this.wrappedKey,
    required this.recoveryWrappedKey,
    this.generation = 0,
  });

  final KdfParams kdf;
  final Uint8List salt;
  final Uint8List wrappedKey;
  final Uint8List recoveryWrappedKey;
  final int generation;

  Map<String, dynamic> toJson() => {
        'generation': generation,
        'kdf': kdf.toJson(),
        'salt': base64.encode(salt),
        'wrapped_key': base64.encode(wrappedKey),
        'recovery_wrapped_key': base64.encode(recoveryWrappedKey),
      };

  factory VaultEnvelope.fromJson(Map<String, dynamic> j) => VaultEnvelope(
        generation: (j['generation'] as num).toInt(),
        kdf: KdfParams.fromJson((j['kdf'] as Map).cast<String, dynamic>()),
        salt: base64.decode(j['salt'] as String),
        wrappedKey: base64.decode(j['wrapped_key'] as String),
        recoveryWrappedKey: base64.decode(j['recovery_wrapped_key'] as String),
      );
}

class NewVault {
  const NewVault({required this.vaultKey, required this.recoveryKey, required this.envelope});
  final Uint8List vaultKey;
  final String recoveryKey; // show once, user writes it down
  final VaultEnvelope envelope;
}

/// Recovery key text: 20 bytes as Crockford base32 in groups of 4
/// (e.g. `7Q2M-...`, 8 groups). Parsing forgives case, spaces, O/0 and I/L/1.
abstract final class RecoveryKey {
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static String format(Uint8List bytes) {
    var bits = 0, value = 0;
    final out = StringBuffer();
    for (final b in bytes) {
      value = (value << 8) | b;
      bits += 8;
      while (bits >= 5) {
        out.write(_alphabet[(value >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) out.write(_alphabet[(value << (5 - bits)) & 31]);
    final s = out.toString();
    return [for (var i = 0; i < s.length; i += 4) s.substring(i, min(i + 4, s.length))].join('-');
  }

  static Uint8List parse(String text) {
    final clean = text
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (clean.length != 32) throw const FormatException('recovery key must have 32 characters');
    var bits = 0, value = 0;
    final out = <int>[];
    for (final ch in clean.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) throw FormatException('invalid character $ch');
      value = ((value << 5) | v) & 0xFFFFF;
      bits += 5;
      if (bits >= 8) {
        out.add((value >> (bits - 8)) & 0xFF);
        bits -= 8;
      }
    }
    return Uint8List.fromList(out);
  }
}
