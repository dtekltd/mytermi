import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/models/host.dart';
import 'package:mytermi/models/ssh_key.dart';
import 'package:mytermi/services/command_store.dart';
import 'package:mytermi/services/host_store.dart';
import 'package:mytermi/services/session_manager.dart';
import 'package:mytermi/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sshDir = Platform.environment['SSH_TEST_DIR'];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('key parsing / generation', () {
    test('generated ed25519 key parses back with matching public key', () {
      final pem = generateEd25519Pem('me@phone');
      expect(pem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      final k = parsePrivateKey(pem, null);
      expect(k.type, 'ssh-ed25519');
      expect(k.publicLine('me@phone'), matches(RegExp(r'^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5\S+ me@phone$')));
      expect(k.fingerprint, matches(RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')));
    });

    test('OpenSSH agrees on the public key and fingerprint', () async {
      final dir = await Directory.systemTemp.createTemp('mytermi_key');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/id')..writeAsStringSync(generateEd25519Pem('x'));
      await Process.run('chmod', ['600', f.path]);
      final k = parsePrivateKey(f.readAsStringSync(), null);
      final pub = await Process.run('ssh-keygen', ['-y', '-f', f.path]);
      expect(pub.exitCode, 0, reason: pub.stderr.toString());
      expect((pub.stdout as String).trim().split(' ').take(2).join(' '), k.publicLine('').trim());
      final fp = await Process.run('ssh-keygen', ['-lf', f.path]);
      expect((fp.stdout as String).split(' ')[1], k.fingerprint);
    }, skip: Process.runSync('which', ['ssh-keygen']).exitCode != 0 ? 'no ssh-keygen' : false);

    test('errors are user friendly', () {
      expect(() => parsePrivateKey('', null), throwsA(isA<KeyParseException>()));
      expect(() => parsePrivateKey('garbage', null),
          throwsA(isA<KeyParseException>().having((e) => e.message, 'msg', 'Key không hợp lệ')));
    });

    test('encrypted key needs the passphrase', () {
      if (sshDir == null) return;
      final pem = File('$sshDir/client').readAsStringSync();
      expect(() => parsePrivateKey(pem, null),
          throwsA(isA<KeyParseException>().having((e) => e.message, 'msg', contains('passphrase'))));
      expect(() => parsePrivateKey(pem, 'wrong'), throwsA(isA<KeyParseException>()));
      expect(parsePrivateKey(pem, 'secret').type, 'ssh-ed25519');
    });
  });

  group('HostStore keys', () {
    test('add, use from hosts, rename, delete', () async {
      final store = await HostStore.load();
      final key = await store.addKey(label: 'laptop', pem: generateEd25519Pem('laptop'));
      expect(store.keys.single.label, 'laptop');
      expect((await store.keySecrets(key.id))!.pem, contains('OPENSSH PRIVATE KEY'));

      await store.save(Host(id: 'a', label: 'a', hostname: 'a', username: 'u', auth: AuthMethod.key, keyId: key.id),
          const HostSecrets());
      await store.save(Host(id: 'b', label: 'b', hostname: 'b', username: 'u', auth: AuthMethod.key, keyId: key.id),
          const HostSecrets());
      await store.save(Host(id: 'c', label: 'c', hostname: 'c', username: 'u', keyId: key.id), const HostSecrets());
      expect(store.hostsUsingKey(key.id).map((h) => h.id), ['a', 'b']);
      expect(store.hosts.last.keyId, isNull, reason: 'password hosts drop keyId');

      await store.renameKey(key, 'macbook');
      final reloaded = await HostStore.load();
      expect(reloaded.keys.single.label, 'macbook');
      expect(reloaded.hosts.first.keyId, key.id);

      await reloaded.deleteKey(reloaded.keys.single);
      expect(reloaded.keys, isEmpty);
      expect(reloaded.hosts.where((h) => h.keyId != null), isEmpty);
      expect(await reloaded.keySecrets(key.id), isNull);
    });

    test('invalid key is not saved', () async {
      final store = await HostStore.load();
      await expectLater(store.addKey(label: 'x', pem: 'nope'), throwsA(isA<KeyParseException>()));
      expect(store.keys, isEmpty);
    });

    test('migrates per-host PEMs into shared keys, deduplicating', () async {
      final pem = generateEd25519Pem('old');
      final other = generateEd25519Pem('other');
      Map<String, dynamic> host(String id) =>
          {'id': id, 'label': id, 'hostname': '$id.lan', 'port': 22, 'username': 'u', 'auth': 'key'};
      SharedPreferences.setMockInitialValues({
        'hosts_v1': jsonEncode([
          host('h1'),
          host('h2'),
          host('h3'),
          {'id': 'p', 'label': 'p', 'hostname': 'p', 'port': 22, 'username': 'u', 'auth': 'password'},
        ]),
      });
      FlutterSecureStorage.setMockInitialValues({
        'key_h1': pem,
        'key_h2': pem, // same key as h1
        'key_h3': other,
        'pw_p': 'pw',
      });
      final store = await HostStore.load();
      expect(store.keys.length, 2);
      final byId = {for (final h in store.hosts) h.id: h};
      expect(byId['h1']!.keyId, byId['h2']!.keyId);
      expect(byId['h3']!.keyId, isNot(byId['h1']!.keyId));
      expect(byId['p']!.keyId, isNull);
      expect(store.keyById(byId['h1']!.keyId)!.label, 'h1');
      const secure = FlutterSecureStorage();
      expect(await secure.read(key: 'key_h1'), isNull, reason: 'old copy removed');
      expect(await secure.read(key: 'pw_p'), 'pw');

      // Persisted: loading again doesn't duplicate.
      final again = await HostStore.load();
      expect(again.keys.length, 2);
      expect(again.hosts.first.keyId, byId['h1']!.keyId);
    });
  });

  group('live connect with a saved key', () {
    Future<SessionStatus> connectWith(HostStore hosts, Host host) async {
      final m = SessionManager(hosts: hosts, commands: await CommandStore.load(), settings: await SettingsStore.load());
      final s = m.open(host)..onHostKey = (_, _, _) async => true;
      s.terminal.resize(80, 24);
      await s.connect();
      final st = s.status;
      m.close(s);
      return st;
    }

    test('imported encrypted key and a freshly generated key both log in', () async {
      final hosts = await HostStore.load();
      final user = Platform.environment['USER']!;

      final imported = await hosts.addKey(
          label: 'client', pem: File('$sshDir/client').readAsStringSync(), passphrase: 'secret');
      final h1 = Host(id: 'h1', label: 'l', hostname: '127.0.0.1', port: 2222, username: user,
          auth: AuthMethod.key, keyId: imported.id);
      await hosts.save(h1, const HostSecrets());
      expect(await connectWith(hosts, h1), SessionStatus.connected);

      // Generated key: install its public line, then connect.
      final gen = await hosts.addKey(label: 'gen', pem: generateEd25519Pem('gen'));
      final ak = File('$sshDir/authorized_keys');
      final before = ak.readAsStringSync();
      addTearDown(() => ak.writeAsStringSync(before));
      ak.writeAsStringSync('$before\n${gen.publicKey}\n');
      final h2 = Host(id: 'h2', label: 'l', hostname: '127.0.0.1', port: 2222, username: user,
          auth: AuthMethod.key, keyId: gen.id);
      await hosts.save(h2, const HostSecrets());
      expect(await connectWith(hosts, h2), SessionStatus.connected);

      // Deleted key: clear error instead of a crash.
      await hosts.deleteKey(gen);
      expect(await connectWith(hosts, hosts.hosts.last), SessionStatus.disconnected);
    }, skip: sshDir == null ? 'set SSH_TEST_DIR to run' : false);
  });
}
