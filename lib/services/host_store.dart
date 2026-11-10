import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/host.dart';

/// Persists the host list (shared_preferences) and secrets (Keychain/Keystore).
class HostStore extends ChangeNotifier {
  HostStore._(this._prefs);

  static const _hostsKey = 'hosts_v1';
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  final SharedPreferences _prefs;
  final List<Host> _hosts = [];

  List<Host> get hosts => List.unmodifiable(_hosts);

  static Future<HostStore> load() async {
    final store = HostStore._(await SharedPreferences.getInstance());
    final raw = store._prefs.getString(_hostsKey);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      store._hosts.addAll(list.map(Host.fromJson));
    }
    return store;
  }

  Future<void> _persist() async {
    await _prefs.setString(_hostsKey, jsonEncode(_hosts.map((h) => h.toJson()).toList()));
    notifyListeners();
  }

  Future<void> save(Host host, HostSecrets secrets) async {
    final i = _hosts.indexWhere((h) => h.id == host.id);
    if (i >= 0) {
      _hosts[i] = host;
    } else {
      _hosts.add(host);
    }
    await _writeSecret('pw_${host.id}', host.auth == AuthMethod.password ? secrets.password : null);
    await _writeSecret('key_${host.id}', host.auth == AuthMethod.key ? secrets.privateKey : null);
    await _writeSecret('pp_${host.id}', host.auth == AuthMethod.key ? secrets.passphrase : null);
    await _persist();
  }

  Future<void> delete(Host host) async {
    _hosts.removeWhere((h) => h.id == host.id);
    for (final p in ['pw_', 'key_', 'pp_']) {
      await _secure.delete(key: '$p${host.id}');
    }
    await _persist();
  }

  Future<HostSecrets> secretsFor(Host host) async => HostSecrets(
        password: await _secure.read(key: 'pw_${host.id}'),
        privateKey: await _secure.read(key: 'key_${host.id}'),
        passphrase: await _secure.read(key: 'pp_${host.id}'),
      );

  Future<void> _writeSecret(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _secure.delete(key: key);
    } else {
      await _secure.write(key: key, value: value);
    }
  }

  // ---- known hosts (host key fingerprints, not secret) ----

  String _khKey(String hostname, int port) => 'kh_$hostname:$port';

  String? knownFingerprint(String hostname, int port) => _prefs.getString(_khKey(hostname, port));

  /// Forget all trusted host keys (next connect asks again).
  Future<int> clearKnownHosts() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith('kh_')).toList();
    for (final k in keys) {
      await _prefs.remove(k);
    }
    return keys.length;
  }

  Future<void> trustFingerprint(String hostname, int port, String fp) =>
      _prefs.setString(_khKey(hostname, port), fp);
}
