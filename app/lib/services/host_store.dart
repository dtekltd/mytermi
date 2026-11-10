import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/host.dart';
import '../models/ssh_key.dart';
import '../util/ids.dart';

/// Persists hosts and saved private keys (metadata in shared_preferences,
/// passwords / PEMs / passphrases in Keychain/Keystore).
class HostStore extends ChangeNotifier {
  HostStore._(this._prefs);

  static const _hostsKey = 'hosts_v1';
  static const _keysKey = 'keys_v1';
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  final SharedPreferences _prefs;
  final List<Host> _hosts = [];
  final List<SshKey> _keys = [];

  List<Host> get hosts => List.unmodifiable(_hosts);
  List<SshKey> get keys => List.unmodifiable(_keys);

  static Future<HostStore> load() async {
    final store = HostStore._(await SharedPreferences.getInstance());
    final raw = store._prefs.getString(_hostsKey);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      store._hosts.addAll(list.map(Host.fromJson));
    }
    final rawKeys = store._prefs.getString(_keysKey);
    if (rawKeys != null) {
      final list = (jsonDecode(rawKeys) as List).cast<Map<String, dynamic>>();
      store._keys.addAll(list.map(SshKey.fromJson));
    }
    await store._migrateInlineKeys();
    return store;
  }

  /// Older versions stored a PEM per host (`key_<hostId>`); move those into the
  /// shared key list (one entry per distinct key) and point the hosts at it.
  Future<void> _migrateInlineKeys() async {
    var changed = false;
    for (final h in _hosts.where((h) => h.auth == AuthMethod.key && h.keyId == null)) {
      final pem = await _secure.read(key: 'key_${h.id}');
      final pp = await _secure.read(key: 'pp_${h.id}');
      if (pem != null && pem.trim().isNotEmpty) {
        try {
          final parsed = parsePrivateKey(pem, pp);
          final existing = _keys.where((k) => k.fingerprint == parsed.fingerprint).firstOrNull;
          h.keyId = existing?.id ?? (await addKey(label: h.displayName, pem: pem, passphrase: pp, persist: false)).id;
        } on KeyParseException {
          continue; // leave it; the user can pick a key in the host editor
        }
      }
      await _secure.delete(key: 'key_${h.id}');
      await _secure.delete(key: 'pp_${h.id}');
      changed = true;
    }
    if (changed) await _persist();
  }

  Future<void> _persist() async {
    await _prefs.setString(_hostsKey, jsonEncode(_hosts.map((h) => h.toJson()).toList()));
    await _prefs.setString(_keysKey, jsonEncode(_keys.map((k) => k.toJson()).toList()));
    notifyListeners();
  }

  // ---- hosts ----

  Future<void> save(Host host, HostSecrets secrets) async {
    if (host.auth != AuthMethod.key) host.keyId = null;
    final i = _hosts.indexWhere((h) => h.id == host.id);
    if (i >= 0) {
      _hosts[i] = host;
    } else {
      _hosts.add(host);
    }
    await _writeSecret('pw_${host.id}', host.auth == AuthMethod.password ? secrets.password : null);
    await _persist();
  }

  Future<void> delete(Host host) async {
    _hosts.removeWhere((h) => h.id == host.id);
    for (final p in ['pw_', 'key_', 'pp_']) {
      await _secure.delete(key: '$p${host.id}');
    }
    await _persist();
  }

  Future<HostSecrets> secretsFor(Host host) async =>
      HostSecrets(password: await _secure.read(key: 'pw_${host.id}'));

  // ---- keys ----

  SshKey? keyById(String? id) => id == null ? null : _keys.where((k) => k.id == id).firstOrNull;

  List<Host> hostsUsingKey(String keyId) =>
      _hosts.where((h) => h.auth == AuthMethod.key && h.keyId == keyId).toList();

  /// Validates and saves a new key. Throws [KeyParseException].
  Future<SshKey> addKey({
    required String label,
    required String pem,
    String? passphrase,
    bool persist = true,
  }) async {
    final parsed = parsePrivateKey(pem, passphrase);
    final key = SshKey(
      id: newId(),
      label: label.trim().isEmpty ? parsed.type : label.trim(),
      type: parsed.type,
      publicKey: parsed.publicLine(label),
      fingerprint: parsed.fingerprint,
      createdAt: DateTime.now(),
    );
    await _secure.write(key: 'sk_${key.id}', value: '${pem.trim()}\n');
    await _writeSecret('skp_${key.id}', passphrase);
    _keys.add(key);
    if (persist) await _persist();
    return key;
  }

  Future<void> renameKey(SshKey key, String label) async {
    key.label = label.trim().isEmpty ? key.typeLabel : label.trim();
    await _persist();
  }

  /// Deletes a key; hosts using it are left without a key until edited.
  Future<void> deleteKey(SshKey key) async {
    _keys.removeWhere((k) => k.id == key.id);
    for (final h in hostsUsingKey(key.id)) {
      h.keyId = null;
    }
    await _secure.delete(key: 'sk_${key.id}');
    await _secure.delete(key: 'skp_${key.id}');
    await _persist();
  }

  Future<KeySecrets?> keySecrets(String keyId) async {
    final pem = await _secure.read(key: 'sk_$keyId');
    if (pem == null) return null;
    final pp = await _secure.read(key: 'skp_$keyId');
    return KeySecrets(pem: pem, passphrase: (pp == null || pp.isEmpty) ? null : pp);
  }

  Future<void> _writeSecret(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _secure.delete(key: key);
    } else {
      await _secure.write(key: key, value: value);
    }
  }

  // ---- sync (apply changes that came from another device) ----

  /// Upserts a host received from sync, keeping its id.
  Future<void> applySyncedHost(Host host, String? password) async {
    final i = _hosts.indexWhere((h) => h.id == host.id);
    i >= 0 ? _hosts[i] = host : _hosts.add(host);
    await _writeSecret('pw_${host.id}', host.auth == AuthMethod.password ? password : null);
    await _persist();
  }

  Future<void> removeHostById(String id) async {
    final h = _hosts.where((h) => h.id == id).firstOrNull;
    if (h != null) await delete(h);
  }

  /// Upserts a key received from sync, keeping its id.
  Future<void> applySyncedKey(SshKey key, String pem, String? passphrase) async {
    final i = _keys.indexWhere((k) => k.id == key.id);
    i >= 0 ? _keys[i] = key : _keys.add(key);
    await _secure.write(key: 'sk_${key.id}', value: pem);
    await _writeSecret('skp_${key.id}', passphrase);
    await _persist();
  }

  Future<void> removeKeyById(String id) async {
    final k = keyById(id);
    if (k != null) await deleteKey(k);
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
