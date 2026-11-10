import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/services/vault_crypto.dart';

void main() {
  // Small Argon2 params keep the tests fast; the format is identical.
  final crypto = VaultCrypto(kdf: const KdfParams(m: 1024, t: 1, p: 1));

  test('recovery key formats and parses back (forgiving input)', () {
    final bytes = VaultCrypto.randomBytes(20);
    final text = RecoveryKey.format(bytes);
    expect(text, matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}$')));
    expect(RecoveryKey.parse(text), bytes);
    final sloppy = text.toLowerCase().replaceAll('-', ' ').replaceAll('0', 'o').replaceAll('1', 'l');
    expect(RecoveryKey.parse(sloppy), bytes);
    expect(() => RecoveryKey.parse('ABCD-EFGH'), throwsFormatException);
    expect(() => RecoveryKey.parse('U' * 32), throwsFormatException);
  });

  test('create, unlock with password or recovery key; wrong ones fail', () async {
    final v = await crypto.create('correct horse');
    expect(v.envelope.wrappedKey.length, 24 + 32 + 16);
    expect(await VaultCrypto.unlockWithPassword(v.envelope, 'correct horse'), v.vaultKey);
    expect(await VaultCrypto.unlockWithRecovery(v.envelope, v.recoveryKey), v.vaultKey);
    await expectLater(VaultCrypto.unlockWithPassword(v.envelope, 'wrong'), throwsA(isA<VaultDecryptException>()));
    final otherRecovery = RecoveryKey.format(VaultCrypto.randomBytes(20));
    await expectLater(VaultCrypto.unlockWithRecovery(v.envelope, otherRecovery), throwsA(isA<VaultDecryptException>()));
  });

  test('envelope JSON round trip (what the server stores)', () async {
    final v = await crypto.create('pw');
    final back = VaultEnvelope.fromJson({...v.envelope.toJson(), 'generation': 42});
    expect(back.generation, 42);
    expect(back.kdf.m, 1024);
    expect(await VaultCrypto.unlockWithPassword(back, 'pw'), v.vaultKey);
  });

  test('rewrap changes the password but keeps the vault key and recovery', () async {
    final v = await crypto.create('old-pass');
    final env2 = await crypto.rewrap(v.vaultKey, 'new-pass', v.envelope);
    expect(await VaultCrypto.unlockWithPassword(env2, 'new-pass'), v.vaultKey);
    await expectLater(VaultCrypto.unlockWithPassword(env2, 'old-pass'), throwsA(isA<VaultDecryptException>()));
    expect(await VaultCrypto.unlockWithRecovery(env2, v.recoveryKey), v.vaultKey);
  });

  test('items: round trip; AAD binds type and id; tampering detected', () async {
    final vk = VaultCrypto.randomBytes(32);
    final payload = {'hostname': '10.0.0.5', 'password': 'hunter2'};
    final data = await VaultCrypto.encryptItem(vk, 'host', 'id-1', payload);
    expect(String.fromCharCodes(data).contains('hunter2'), isFalse);
    expect(await VaultCrypto.decryptItem(vk, 'host', 'id-1', data), payload);
    // Same ciphertext under another id/type (server swapping items) fails.
    await expectLater(VaultCrypto.decryptItem(vk, 'host', 'id-2', data), throwsA(isA<VaultDecryptException>()));
    await expectLater(VaultCrypto.decryptItem(vk, 'key', 'id-1', data), throwsA(isA<VaultDecryptException>()));
    final tampered = Uint8List.fromList(data)..[30] ^= 1;
    await expectLater(VaultCrypto.decryptItem(vk, 'host', 'id-1', tampered), throwsA(isA<VaultDecryptException>()));
    // Fresh nonce each time.
    expect(await VaultCrypto.encryptItem(vk, 'host', 'id-1', payload), isNot(data));
  });

  test('standard params are Argon2id 64 MiB / t=3', () {
    expect(KdfParams.standard.toJson(), {'alg': 'argon2id', 'm': 65536, 't': 3, 'p': 1});
  });
}
