// Live end-to-end sync test against a running MyTermi server in dev mode.
//   SYNC_TEST_SERVER=http://127.0.0.1:18080 SYNC_TEST_LOG=/path/server.log flutter test test/sync_live_test.dart
// Device A is the real app stack (stores + SyncService); device B talks to the
// API directly and does its own crypto, like a second phone would.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mytermi/models/host.dart';
import 'package:mytermi/models/snippet.dart';
import 'package:mytermi/models/ssh_key.dart';
import 'package:mytermi/services/account_service.dart';
import 'package:mytermi/services/command_store.dart';
import 'package:mytermi/services/host_store.dart';
import 'package:mytermi/services/sync_service.dart';
import 'package:mytermi/services/vault_crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

final server = Platform.environment['SYNC_TEST_SERVER'];
final logPath = Platform.environment['SYNC_TEST_LOG'];

/// Reads the latest dev-mode OTP for [email] from the server log.
Future<String> codeFor(String email) async {
  for (var i = 0; i < 20; i++) {
    final lines = File(logPath!).readAsLinesSync().where((l) => l.contains('to=$email') && l.contains('DEV MAIL'));
    if (lines.isNotEmpty) return RegExp(r'subject="(\d{6})').firstMatch(lines.last)!.group(1)!;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('no code for $email');
}

/// Device B: raw API + crypto.
class DeviceB {
  DeviceB(this.token);
  final String token;
  late Uint8List vk;
  late int generation;

  Future<Map<String, dynamic>> call(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$server/api/v1$path'))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json';
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await req.send());
    return res.body.isEmpty ? {} : jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> unlock(String password) async {
    final env = VaultEnvelope.fromJson(await call('GET', '/vault'));
    vk = await VaultCrypto.unlockWithPassword(env, password);
    generation = env.generation;
  }

  /// Decrypted items by type: localId → payload (null = tombstone).
  Future<Map<String, Map<String, Map<String, dynamic>?>>> pull() async {
    final r = await call('GET', '/sync?since=0&generation=$generation');
    final out = <String, Map<String, Map<String, dynamic>?>>{};
    for (final it in (r['items'] as List).cast<Map<String, dynamic>>()) {
      final type = it['type'] as String;
      if (it['deleted'] == true) {
        out.putIfAbsent(type, () => {})['tomb:${it['id']}'] = null;
        continue;
      }
      final raw = base64.decode(it['data'] as String);
      expect(utf8.decode(raw, allowMalformed: true).contains('hunter2'), isFalse, reason: 'server sees ciphertext only');
      final p = await VaultCrypto.decryptItem(vk, type, it['id'] as String, raw);
      out.putIfAbsent(type, () => {})[p['id'] as String] = p;
    }
    return out;
  }

  Future<Map<String, dynamic>> push(String type, String localId, Map<String, dynamic> payload, DateTime mod) async {
    final id = syncId(type, localId);
    final data = await VaultCrypto.encryptItem(vk, type, id, payload);
    return call('POST', '/sync', {
      'generation': generation,
      'items': [
        {'id': id, 'type': type, 'modified_at': mod.toUtc().toIso8601String(), 'data': base64.encode(data)}
      ],
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two devices sync hosts, keys and snippets end to end', () async {
    HttpOverrides.global = null; // allow real HTTP in tests
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final email = 'sync${DateTime.now().millisecondsSinceEpoch}@example.com';

    // ---- device A: sign up with an email code
    final account = await AccountService.load();
    await account.setServerUrl(server!);
    await account.startEmail(email);
    final signIn = await account.verifyEmail(email, await codeFor(email));
    expect(signIn.isNewUser, isTrue);
    await account.setPassword('device-pass-1');

    final hosts = await HostStore.load();
    final commands = await CommandStore.load();
    final sync = SyncService(
      account: account,
      hosts: hosts,
      commands: commands,
      prefs: await SharedPreferences.getInstance(),
      crypto: VaultCrypto(kdf: const KdfParams(m: 8192, t: 2, p: 1)),
    );
    await sync.init();
    await Future.delayed(const Duration(milliseconds: 300));
    expect(sync.phase, SyncPhase.needsVault);

    // Local data before enabling sync.
    final key = await hosts.addKey(label: 'laptop', pem: generateEd25519Pem('laptop'));
    await hosts.save(
        Host(id: 'h1', label: 'prod', hostname: '10.0.0.5', username: 'ubuntu', auth: AuthMethod.password),
        const HostSecrets(password: 'hunter2'));
    await hosts.save(
        Host(id: 'h2', label: 'db', hostname: 'db.lan', username: 'root', auth: AuthMethod.key, keyId: key.id),
        const HostSecrets());
    await commands.saveSnippet(Snippet(id: 's1', name: 'Disk', command: 'df -h'));

    final recovery = await sync.enable('vault-pass-1');
    expect(RecoveryKey.parse(recovery).length, 20);
    await sync.syncNow();
    expect(sync.phase, SyncPhase.ready);
    expect(sync.error, isNull);
    expect(sync.pendingChanges, 0);
    expect(sync.syncedItems, 4);

    // ---- device B: password login, unlock, read everything
    final login = jsonDecode((await http.post(Uri.parse('$server/api/v1/auth/password'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': 'device-pass-1', 'device': {'id': 'device-b'}})))
        .body) as Map<String, dynamic>;
    final b = DeviceB(login['access_token'] as String);
    await expectLater(b.unlock('wrong-vault-pass'), throwsA(isA<VaultDecryptException>()));
    await b.unlock('vault-pass-1');
    var remote = await b.pull();
    expect(remote['host']!['h1']!['password'], 'hunter2');
    expect(remote['host']!['h2']!['keyId'], key.id);
    expect(remote['key']![key.id]!['pem'], contains('OPENSSH PRIVATE KEY'));
    expect(remote['snippet']!['s1']!['command'], 'df -h');

    // ---- B renames a host and adds a snippet; A pulls them
    final h1 = Map<String, dynamic>.from(remote['host']!['h1']!)..['label'] = 'prod (renamed on B)';
    await b.push('host', 'h1', h1, DateTime.now());
    await b.push('snippet', 's2', {'id': 's2', 'name': 'Logs', 'command': 'journalctl -f', 'autoRun': true}, DateTime.now());
    await sync.syncNow();
    expect(hosts.hosts.firstWhere((h) => h.id == 'h1').label, 'prod (renamed on B)');
    expect((await hosts.secretsFor(hosts.hosts.firstWhere((h) => h.id == 'h1'))).password, 'hunter2');
    expect(commands.snippets.map((s) => s.command), contains('journalctl -f'));
    expect(sync.pendingChanges, 0, reason: 'applying remote changes must not mark them dirty');

    // ---- A deletes a snippet and edits a host; B sees a tombstone and the edit
    await commands.deleteSnippet(commands.snippets.firstWhere((s) => s.id == 's1'));
    final h2 = hosts.hosts.firstWhere((h) => h.id == 'h2')..label = 'database';
    await hosts.save(h2, const HostSecrets());
    await Future.delayed(const Duration(milliseconds: 600)); // change detection debounce
    expect(sync.pendingChanges, 2);
    await sync.syncNow();
    remote = await b.pull();
    expect(remote['snippet']!.containsKey('s1'), isFalse);
    expect(remote['snippet']!.keys.where((k) => k.startsWith('tomb:')), hasLength(1));
    expect(remote['host']!['h2']!['label'], 'database');

    // ---- conflict: A edits offline (older), B edits later → B wins on A
    final h1a = hosts.hosts.firstWhere((h) => h.id == 'h1')..label = 'edited on A';
    await hosts.save(h1a, const HostSecrets(password: 'hunter2'));
    await Future.delayed(const Duration(milliseconds: 600));
    await Future.delayed(const Duration(milliseconds: 50));
    final h1b = Map<String, dynamic>.from((await b.pull())['host']!['h1']!)..['label'] = 'edited on B (newer)';
    await b.push('host', 'h1', h1b, DateTime.now());
    await sync.syncNow();
    expect(hosts.hosts.firstWhere((h) => h.id == 'h1').label, 'edited on B (newer)');
    expect(sync.pendingChanges, 0);

    // ---- vault password change keeps devices working; new password unlocks
    await sync.changePassword('vault-pass-1', 'vault-pass-2');
    await expectLater(b.unlock('vault-pass-1'), throwsA(isA<VaultDecryptException>()));
    await b.unlock('vault-pass-2');

    // ---- B resets the vault: A notices and locks itself
    await b.call('DELETE', '/vault', {'confirm': 'RESET'});
    await sync.syncNow();
    expect(sync.phase, anyOf(SyncPhase.needsVault, SyncPhase.locked));
    expect(hosts.hosts, hasLength(2), reason: 'local data is kept');

    // ---- sign out clears sync state but keeps local data
    await account.signOut();
    expect(sync.phase, SyncPhase.off);
    expect(hosts.hosts, hasLength(2));
    sync.dispose();
  }, skip: server == null || logPath == null ? 'set SYNC_TEST_SERVER and SYNC_TEST_LOG' : false, timeout: const Timeout(Duration(minutes: 2)));
}
