// Live: what happens to an SshSession after the remote shell ends.
// Runs only with SSH_TEST_DIR (see ssh_live_test.dart).
import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/models/host.dart';
import 'package:mytermi/services/command_store.dart';
import 'package:mytermi/services/host_store.dart';
import 'package:mytermi/services/session_manager.dart';
import 'package:mytermi/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Platform.environment['SSH_TEST_DIR'];

  Future<(SessionManager, SshSession)> connected() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final hosts = await HostStore.load();
    final key = await hosts.addKey(label: 'c', pem: File('$dir/client').readAsStringSync(), passphrase: 'secret');
    final host = Host(id: 'h', label: 'h', hostname: '127.0.0.1', port: 2222,
        username: Platform.environment['USER']!, auth: AuthMethod.key, keyId: key.id);
    await hosts.save(host, const HostSecrets());
    final m = SessionManager(hosts: hosts, commands: await CommandStore.load(), settings: await SettingsStore.load());
    final s = m.open(host)..onHostKey = (_, _, _) async => true;
    s.terminal.resize(80, 24);
    await s.connect();
    expect(s.status, SessionStatus.connected);
    return (m, s);
  }

  Future<void> waitFor(bool Function() cond) async {
    for (var i = 0; i < 50 && !cond(); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  test('after `exit`, resizing / typing does not throw and reconnect works', () async {
    final (m, s) = await connected();
    s.send('exit\r');
    await waitFor(() => s.status == SessionStatus.disconnected);
    expect(s.status, SessionStatus.disconnected);

    // Layout changes after the shell ended (keyboard hide, rotation, pinch).
    final errors = <Object>[];
    void guard(void Function() f) {
      try {
        f();
      } catch (e) {
        errors.add(e);
      }
    }

    // Async errors (e.g. from a channel request) would land in this zone.
    runZonedGuarded(() {
      guard(() => s.terminal.resize(100, 30));
      guard(() => s.terminal.resize(60, 20));
      guard(() => s.send('ls\r'));
    }, (e, _) => errors.add(e));
    await Future.delayed(const Duration(milliseconds: 300));
    expect(errors, isEmpty);

    await s.connect();
    expect(s.status, SessionStatus.connected);
    s.terminal.resize(90, 25); // live session still resizes fine
    m.close(s);
  }, skip: dir == null ? 'set SSH_TEST_DIR to run' : false);
}
