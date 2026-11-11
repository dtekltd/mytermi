import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/host.dart';
import '../models/snippet.dart';
import '../models/ssh_key.dart';
import 'account_service.dart';
import 'api_client.dart';
import 'command_store.dart';
import 'host_store.dart';
import 'vault_crypto.dart';

enum SyncPhase {
  /// Not signed in.
  off,

  /// Signed in, no vault on the server yet: user must set a vault password.
  needsVault,

  /// A vault exists but this device hasn't unlocked it.
  locked,

  /// Unlocked; syncing in the background.
  ready,
}

/// Local copy of one entity, in the exact shape that gets encrypted.
class _Local {
  _Local(this.type, this.localId, this.payload) : hash = _hash(payload);
  final String type;
  final String localId;
  final Map<String, dynamic> payload;
  final String hash;
}

String _hash(Map<String, dynamic> m) => sha256.convert(utf8.encode(jsonEncode(m))).toString();

/// Server item id: a UUID derived from the entity type and its local id.
String syncId(String type, String localId) {
  final b = sha256.convert(utf8.encode('mytermi:$type:$localId')).bytes.sublist(0, 16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Sync bookkeeping persisted between launches.
class _State {
  int rev = 0;
  int generation = 0;

  /// Last synced version of each item: id → {type, local, hash}.
  Map<String, Map<String, String>> entries = {};

  /// Local edits not yet pushed: id → when they happened.
  Map<String, DateTime> dirty = {};

  Map<String, dynamic> toJson() => {
    'rev': rev,
    'generation': generation,
    'entries': entries,
    'dirty': dirty.map((k, v) => MapEntry(k, v.toUtc().toIso8601String())),
  };

  static _State fromJson(Map<String, dynamic> j) => _State()
    ..rev = (j['rev'] ?? 0) as int
    ..generation = (j['generation'] ?? 0) as int
    ..entries = ((j['entries'] ?? {}) as Map).map((k, v) => MapEntry(k as String, (v as Map).cast<String, String>()))
    ..dirty = ((j['dirty'] ?? {}) as Map).map((k, v) => MapEntry(k as String, DateTime.parse(v as String)));
}

/// End-to-end encrypted sync of hosts, keys and snippets.
///
/// Local stores stay the source of truth. Edits are noticed through store
/// listeners (marked dirty with a timestamp), then pushed; remote changes are
/// pulled incrementally and applied with last-writer-wins.
class SyncService extends ChangeNotifier with WidgetsBindingObserver {
  SyncService({
    required this.account,
    required this.hosts,
    required this.commands,
    required SharedPreferences prefs,
    FlutterSecureStorage? secure,
    VaultCrypto? crypto,
  }) : _prefs = prefs, // ignore: prefer_initializing_formals
       _secure = secure ?? _defaultSecure,
       _crypto = crypto ?? VaultCrypto();

  static const _defaultSecure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _kState = 'sync_state_v1', _kVk = 'sync_vk', _kLast = 'sync_last';

  final AccountService account;
  final HostStore hosts;
  final CommandStore commands;
  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  final VaultCrypto _crypto;

  ApiClient get _api => account.api;

  _State _state = _State();
  Uint8List? _vk;
  SyncPhase _phase = SyncPhase.off;
  bool _syncing = false;
  bool _again = false;
  String? _error;
  DateTime? _lastSynced;
  Timer? _detectTimer, _syncTimer, _periodic;
  int _localItems = 0;

  SyncPhase get phase => _phase;
  bool get syncing => _syncing;
  String? get error => _error;
  DateTime? get lastSynced => _lastSynced;
  int get pendingChanges => _state.dirty.length;
  int get syncedItems => _state.entries.length;
  int get localItems => _localItems;

  @visibleForTesting
  void debugSet({required SyncPhase phase, DateTime? lastSynced, int synced = 0, int pending = 0}) {
    _phase = phase;
    _lastSynced = lastSynced;
    _state.entries = {for (var i = 0; i < synced; i++) 'e$i': {'type': 'host', 'local': '$i', 'hash': ''}};
    _state.dirty = {for (var i = 0; i < pending; i++) 'd$i': DateTime.now()};
    notifyListeners();
  }

  /// Loads local state and starts listening. Call once at startup.
  Future<void> init() async {
    final raw = _prefs.getString(_kState);
    if (raw != null) _state = _State.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    final vk = await _secure.read(key: _kVk);
    if (vk != null) _vk = base64.decode(vk);
    final last = _prefs.getString(_kLast);
    if (last != null) _lastSynced = DateTime.parse(last);

    hosts.addListener(_onLocalChange);
    commands.addListener(_onLocalChange);
    account.addListener(_onAccountChange);
    account.onSignedOut.add(_onSignedOut);
    WidgetsBinding.instance.addObserver(this);

    _phase = !account.signedIn ? SyncPhase.off : (_vk != null ? SyncPhase.ready : SyncPhase.locked);
    notifyListeners();
    if (account.signedIn) unawaited(refresh());
  }

  @override
  void dispose() {
    hosts.removeListener(_onLocalChange);
    commands.removeListener(_onLocalChange);
    account.removeListener(_onAccountChange);
    WidgetsBinding.instance.removeObserver(this);
    _detectTimer?.cancel();
    _syncTimer?.cancel();
    _periodic?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _phase == SyncPhase.ready) unawaited(syncNow());
  }

  bool _wasSignedIn = false;
  void _onAccountChange() {
    final now = account.signedIn;
    if (now && !_wasSignedIn) unawaited(refresh());
    _wasSignedIn = now;
  }

  /// Re-checks the server vault and syncs if unlocked.
  Future<void> refresh() async {
    if (!account.signedIn) return _setPhase(SyncPhase.off);
    try {
      final env = await _fetchVault();
      if (env == null) {
        await _forgetVault();
        _setPhase(SyncPhase.needsVault);
      } else if (_vk != null && env.generation == _state.generation) {
        _setPhase(SyncPhase.ready);
        await syncNow();
      } else {
        await _forgetVault(); // reset elsewhere, or never unlocked here
        _setPhase(SyncPhase.locked);
      }
      _error = null;
    } on ApiException catch (e) {
      _error = e.friendly;
    }
    notifyListeners();
  }

  void _setPhase(SyncPhase p) {
    _phase = p;
    _periodic?.cancel();
    if (p == SyncPhase.ready) {
      _periodic = Timer.periodic(const Duration(minutes: 5), (_) => syncNow());
    }
    notifyListeners();
  }

  Future<VaultEnvelope?> _fetchVault() async {
    try {
      return VaultEnvelope.fromJson(await _api.call('GET', '/vault'));
    } on ApiException catch (e) {
      if (e.code == 'vault_not_found') return null;
      rethrow;
    }
  }

  // ---------------------------------------------------------------- vault

  /// First device: creates the vault. Returns the recovery key to show once.
  Future<String> enable(String password) async {
    final v = await _crypto.create(password);
    final r = await _api.call('POST', '/vault', body: v.envelope.toJson());
    await _adoptKey(v.vaultKey, (r['generation'] as num).toInt());
    unawaited(syncNow());
    return v.recoveryKey;
  }

  /// Throws [VaultDecryptException] for a wrong password.
  Future<void> unlock(String password) async {
    final env = await _fetchVault();
    if (env == null) return _setPhase(SyncPhase.needsVault);
    await _adoptKey(await VaultCrypto.unlockWithPassword(env, password), env.generation);
    await syncNow();
  }

  /// Unlock with the recovery key, then set a new vault password.
  /// Throws [FormatException] / [VaultDecryptException].
  Future<void> recover(String recoveryKey, String newPassword) async {
    final env = await _fetchVault();
    if (env == null) return _setPhase(SyncPhase.needsVault);
    final vk = await VaultCrypto.unlockWithRecovery(env, recoveryKey);
    final env2 = await _crypto.rewrap(vk, newPassword, env);
    await _api.call('PUT', '/vault', body: {...env2.toJson(), 'generation': env.generation});
    await _adoptKey(vk, env.generation);
    await syncNow();
  }

  /// Changes the vault password (this device must be unlocked). Other devices
  /// stay unlocked; the old password stops working for new devices.
  Future<void> changePassword(String currentPassword, String newPassword) async {
    final env = await _fetchVault();
    if (env == null || _vk == null) throw StateError('vault not unlocked');
    final vk = await VaultCrypto.unlockWithPassword(env, currentPassword); // proves the old password
    final env2 = await _crypto.rewrap(vk, newPassword, env);
    await _api.call('PUT', '/vault', body: {...env2.toJson(), 'generation': env.generation});
  }

  /// Forgot both password and recovery key: wipe the server vault and start
  /// over from this device's data. Returns the new recovery key.
  Future<String> resetVault(String newPassword) async {
    await _api.call('DELETE', '/vault', body: {'confirm': 'RESET'});
    await _forgetVault();
    return enable(newPassword);
  }

  Future<void> _adoptKey(Uint8List vk, int generation) async {
    _vk = vk;
    await _secure.write(key: _kVk, value: base64.encode(vk));
    if (generation != _state.generation) _state = _State()..generation = generation;
    await _saveState();
    _error = null;
    _setPhase(SyncPhase.ready);
  }

  /// Drops the key and bookkeeping (local data is kept).
  Future<void> _forgetVault() async {
    _vk = null;
    _state = _State();
    await _secure.delete(key: _kVk);
    await _saveState();
  }

  Future<void> _onSignedOut() async {
    await _forgetVault();
    await _prefs.remove(_kLast);
    _lastSynced = null;
    _error = null;
    _setPhase(SyncPhase.off);
  }

  Future<void> _saveState() => _prefs.setString(_kState, jsonEncode(_state.toJson()));

  // ------------------------------------------------------------- snapshot

  static String? _nz(String? s) => (s == null || s.isEmpty) ? null : s;

  static Map<String, dynamic> hostPayload(Host h, String? password) => {...h.toJson(), 'password': _nz(password)};

  static Map<String, dynamic> keyPayload(SshKey k, KeySecrets s) => {
    ...k.toJson(),
    'pem': s.pem,
    'passphrase': _nz(s.passphrase),
  };

  static Map<String, dynamic> snippetPayload(Snippet s) => s.toJson();

  Future<Map<String, _Local>> _snapshot() async {
    final out = <String, _Local>{};
    for (final k in hosts.keys) {
      final s = await hosts.keySecrets(k.id);
      if (s == null) continue;
      out[syncId('key', k.id)] = _Local('key', k.id, keyPayload(k, s));
    }
    for (final h in hosts.hosts) {
      final pw = h.auth == AuthMethod.password ? (await hosts.secretsFor(h)).password : null;
      out[syncId('host', h.id)] = _Local('host', h.id, hostPayload(h, pw));
    }
    for (final s in commands.snippets) {
      out[syncId('snippet', s.id)] = _Local('snippet', s.id, snippetPayload(s));
    }
    _localItems = out.length;
    return out;
  }

  // ------------------------------------------------------- change tracking

  void _onLocalChange() {
    if (_phase != SyncPhase.ready) return;
    _detectTimer?.cancel();
    _detectTimer = Timer(const Duration(milliseconds: 400), () async {
      if (await _detectChanges()) _scheduleSync();
    });
  }

  /// Marks edited / deleted items dirty. Returns true if anything is pending.
  Future<bool> _detectChanges() async {
    final snap = await _snapshot();
    final now = DateTime.now().toUtc();
    var changed = false;
    for (final MapEntry(key: id, value: l) in snap.entries) {
      final synced = _state.entries[id]?['hash'];
      if (synced == l.hash) {
        changed |= _state.dirty.remove(id) != null; // edited back to the synced version
      } else if (!_state.dirty.containsKey(id)) {
        _state.dirty[id] = now;
        changed = true;
      }
    }
    for (final id in _state.entries.keys) {
      if (!snap.containsKey(id) && !_state.dirty.containsKey(id)) {
        _state.dirty[id] = now; // deleted locally
        changed = true;
      }
    }
    if (changed) await _saveState();
    notifyListeners();
    return _state.dirty.isNotEmpty;
  }

  void _scheduleSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(seconds: 2), syncNow);
  }

  // ----------------------------------------------------------------- sync

  Future<void>? _inflight;

  /// Pull then push. Safe to call any time: a call made while a sync is
  /// running schedules one more round and completes when that round is done.
  Future<void> syncNow() {
    if (_phase != SyncPhase.ready || _vk == null || !account.signedIn) return Future.value();
    if (_inflight != null) {
      _again = true;
      return _inflight!;
    }
    return _inflight = _run().whenComplete(() => _inflight = null);
  }

  Future<void> _run() async {
    _syncing = true;
    notifyListeners();
    try {
      do {
        _again = false;
        await _detectChanges();
        await _pull();
        await _push();
      } while (_again);
      _lastSynced = DateTime.now();
      await _prefs.setString(_kLast, _lastSynced!.toIso8601String());
      _error = null;
    } on ApiException catch (e) {
      if (e.code == 'vault_generation') {
        await _forgetVault();
        _setPhase(SyncPhase.locked);
      } else if (e.code == 'vault_not_found') {
        await _forgetVault();
        _setPhase(SyncPhase.needsVault);
      }
      _error = e.friendly;
    } catch (e) {
      _error = 'Sync error: $e';
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _pull() async {
    var since = _state.rev;
    while (true) {
      final r = await _api.call('GET', '/sync', query: {'since': '$since', 'generation': '${_state.generation}'});
      for (final it in (r['items'] as List).cast<Map<String, dynamic>>()) {
        await _applyRemote(it);
      }
      since = (r['rev'] as num).toInt();
      _state.rev = since;
      await _saveState();
      if (r['more'] != true) break;
    }
  }

  Future<void> _push() async {
    if (_state.dirty.isEmpty) return;
    final snap = await _snapshot();
    final ids = _state.dirty.keys.toList();
    for (var i = 0; i < ids.length; i += 200) {
      final batch = ids.skip(i).take(200);
      final items = <Map<String, dynamic>>[];
      for (final id in batch) {
        final local = snap[id];
        final mod = _state.dirty[id]!.toUtc().toIso8601String();
        if (local != null) {
          final data = await VaultCrypto.encryptItem(_vk!, local.type, id, local.payload);
          items.add({'id': id, 'type': local.type, 'modified_at': mod, 'deleted': false, 'data': base64.encode(data)});
        } else {
          final type = _state.entries[id]?['type'];
          if (type == null) {
            _state.dirty.remove(id); // created and deleted before ever syncing
            continue;
          }
          items.add({'id': id, 'type': type, 'modified_at': mod, 'deleted': true});
        }
      }
      if (items.isEmpty) continue;
      final r = await _api.call('POST', '/sync', body: {'generation': _state.generation, 'items': items});
      for (final a in (r['accepted'] as List).cast<Map<String, dynamic>>()) {
        final id = a['id'] as String;
        final local = snap[id];
        if (a['deleted'] == true || local == null) {
          _state.entries.remove(id);
        } else {
          _state.entries[id] = {'type': local.type, 'local': local.localId, 'hash': local.hash};
        }
        _state.dirty.remove(id);
      }
      for (final c in (r['conflicts'] as List).cast<Map<String, dynamic>>()) {
        await _applyRemote(c, force: true); // the server copy is newer
      }
      await _saveState();
    }
  }

  /// Applies a server item unless a newer local edit exists.
  Future<void> _applyRemote(Map<String, dynamic> it, {bool force = false}) async {
    final id = it['id'] as String;
    final type = it['type'] as String;
    final localEdit = _state.dirty[id];
    if (!force && localEdit != null && !DateTime.parse(it['modified_at'] as String).isAfter(localEdit)) {
      return; // our edit is newer; it will be pushed
    }
    if (it['deleted'] == true) {
      final localId = _state.entries[id]?['local'];
      if (localId != null) {
        switch (type) {
          case 'host':
            await hosts.removeHostById(localId);
          case 'key':
            await hosts.removeKeyById(localId);
          case 'snippet':
            final s = commands.snippets.where((s) => s.id == localId).firstOrNull;
            if (s != null) await commands.deleteSnippet(s);
        }
      }
      _state.entries.remove(id);
      _state.dirty.remove(id);
      return;
    }
    final Map<String, dynamic> p;
    try {
      p = await VaultCrypto.decryptItem(_vk!, type, id, base64.decode(it['data'] as String));
    } on VaultDecryptException {
      _error = 'A synced item couldn\'t be decrypted and was skipped.';
      return;
    }
    final _Local applied;
    switch (type) {
      case 'host':
        final h = Host.fromJson(p);
        final pw = p['password'] as String?;
        await hosts.applySyncedHost(h, pw);
        applied = _Local(type, h.id, hostPayload(h, h.auth == AuthMethod.password ? pw : null));
      case 'key':
        final k = SshKey.fromJson(p);
        final s = KeySecrets(pem: p['pem'] as String, passphrase: p['passphrase'] as String?);
        await hosts.applySyncedKey(k, s.pem, s.passphrase);
        applied = _Local(type, k.id, keyPayload(k, s));
      case 'snippet':
        final s = Snippet.fromJson(p);
        await commands.saveSnippet(s);
        applied = _Local(type, s.id, snippetPayload(s));
      default:
        return; // newer app version's type: ignore
    }
    _state.entries[id] = {'type': type, 'local': applied.localId, 'hash': applied.hash};
    _state.dirty.remove(id);
  }
}
