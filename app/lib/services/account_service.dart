import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../env.dart';
import '../util/ids.dart';
import 'api_client.dart';

/// The signed-in user, as returned by GET /me.
class Account {
  Account.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      email = j['email'] as String,
      name = (j['name'] ?? '') as String,
      role = (j['role'] ?? 'user') as String,
      hasPassword = (j['has_password'] ?? false) as bool,
      providers = ((j['providers'] ?? []) as List).cast<String>(),
      planId = (j['plan']?['id'] ?? 'free') as String,
      planName = (j['plan']?['name'] ?? 'Free') as String,
      maxDevices = (j['plan']?['max_devices'] ?? 0) as int,
      syncEnabled = (j['plan']?['sync_enabled'] ?? true) as bool,
      hasVault = (j['has_vault'] ?? false) as bool,
      raw = j;

  final String id, email, name, role, planId, planName;
  final bool hasPassword, syncEnabled, hasVault;
  final List<String> providers;
  final int maxDevices;
  final Map<String, dynamic> raw;
}

/// Server-side config (GET /config): which sign-in methods are enabled.
class ServerConfig {
  const ServerConfig({
    this.appName = 'MyTermi',
    this.signupEnabled = true,
    this.email = true,
    this.google = false,
    this.apple = false,
  });

  ServerConfig.fromJson(Map<String, dynamic> j)
    : appName = (j['app_name'] ?? 'MyTermi') as String,
      signupEnabled = (j['signup_enabled'] ?? true) as bool,
      email = (j['providers']?['email'] ?? false) as bool,
      google = (j['providers']?['google'] ?? false) as bool,
      apple = (j['providers']?['apple'] ?? false) as bool;
  final String appName;
  final bool signupEnabled, email, google, apple;
}

/// Result of a successful sign-in.
class SignInResult {
  SignInResult(this.account, this.isNewUser);
  final Account account;
  final bool isNewUser;
}

/// Sign-in state, tokens (Keychain/Keystore) and account calls.
class AccountService extends ChangeNotifier implements TokenStore {
  AccountService._(this._prefs, {FlutterSecureStorage? secure}) : _secure = secure ?? _defaultSecure {
    api = ApiClient(baseUrl: serverUrl, tokens: this);
  }

  static const _defaultSecure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _kServer = 'acct_server', _kAccount = 'acct_me';
  static const _kRefresh = 'acct_refresh', _kDevice = 'acct_device';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  late final ApiClient api;

  Account? _account;
  String? _access, _refresh, _deviceId;
  DateTime? _accessExp;

  /// Called after sign-out / session loss so other services can clear state.
  final List<Future<void> Function()> onSignedOut = [];

  static Future<AccountService> load({FlutterSecureStorage? secure}) async {
    final s = AccountService._(await SharedPreferences.getInstance(), secure: secure);
    s._refresh = await s._secure.read(key: _kRefresh);
    s._deviceId = await s._secure.read(key: _kDevice);
    if (s._deviceId == null) {
      s._deviceId = newId();
      await s._secure.write(key: _kDevice, value: s._deviceId);
    }
    final cached = s._prefs.getString(_kAccount);
    if (s._refresh != null && cached != null) {
      s._account = Account.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    }
    return s;
  }

  Account? get account => _account;
  bool get signedIn => _account != null && _refresh != null;
  String get deviceId => _deviceId!;

  String get serverUrl => _prefs.getString(_kServer) ?? defaultApiUrl;
  Future<void> setServerUrl(String url) async {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.isNotEmpty && !u.startsWith(RegExp('https?://'))) u = 'https://$u';
    await _prefs.setString(_kServer, u);
    api.baseUrl = u;
    notifyListeners();
  }

  Map<String, String> get _device => {
    'id': deviceId,
    'name': switch (Platform.operatingSystem) {
      'ios' => 'iPhone / iPad',
      'android' => 'Android',
      'windows' => 'Windows',
      'macos' => 'Mac',
      'linux' => 'Linux',
      final os => os,
    },
    'platform': Platform.operatingSystem,
  };

  // ---- TokenStore ----

  @override
  String? get accessToken => _access;
  @override
  DateTime? get accessExpiry => _accessExp;
  @override
  String? get refreshToken => _refresh;

  @override
  Future<void> saveTokens(String access, DateTime expiry, String refresh) async {
    _access = access;
    _accessExp = expiry;
    _refresh = refresh;
    await _secure.write(key: _kRefresh, value: refresh);
  }

  @override
  Future<void> onSessionLost() => _clear();

  // ---- sign-in flows ----

  Future<ServerConfig> fetchConfig() async => ServerConfig.fromJson(await api.get('/config', auth: false));

  /// Sends a 6-digit code to [email] (sign up, sign in or forgot password).
  Future<void> startEmail(String email) => api.post('/auth/email/start', {'email': email.trim()});

  Future<SignInResult> verifyEmail(String email, String code) =>
      _signIn('/auth/email/verify', {'email': email.trim(), 'code': code.trim()});

  Future<SignInResult> signInWithPassword(String email, String password) =>
      _signIn('/auth/password', {'email': email.trim(), 'password': password});

  /// Returns null if the user cancelled.
  Future<SignInResult?> signInWithGoogle() async {
    final g = GoogleSignIn.instance;
    await g.initialize(
      clientId: googleIosClientId.isEmpty ? null : googleIosClientId,
      serverClientId: googleServerClientId.isEmpty ? null : googleServerClientId,
    );
    try {
      final acct = await g.authenticate();
      final token = acct.authentication.idToken;
      if (token == null) throw ApiException(0, 'invalid_id_token', 'Google returned no ID token');
      return await _signIn('/auth/google', {'id_token': token});
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Returns null if the user cancelled.
  Future<SignInResult?> signInWithApple() async {
    try {
      final cred = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      );
      final token = cred.identityToken;
      if (token == null) throw ApiException(0, 'invalid_id_token', 'Apple returned no identity token');
      final name = [cred.givenName, cred.familyName].whereType<String>().join(' ').trim();
      return await _signIn('/auth/apple', {'identity_token': token, 'name': name});
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      rethrow;
    }
  }

  Future<SignInResult> _signIn(String path, Map<String, dynamic> body) async {
    final r = await api.post(path, {...body, 'device': _device});
    await saveTokens(
      r['access_token'] as String,
      DateTime.parse(r['expires_at'] as String),
      r['refresh_token'] as String,
    );
    await _setAccount((r['user'] as Map).cast<String, dynamic>());
    return SignInResult(_account!, (r['is_new_user'] ?? false) as bool);
  }

  Future<void> _setAccount(Map<String, dynamic> j) async {
    _account = Account.fromJson(j);
    await _prefs.setString(_kAccount, jsonEncode(j));
    notifyListeners();
  }

  // ---- account ----

  Future<Account?> refreshAccount() async {
    if (_refresh == null) return null;
    await _setAccount(await api.call('GET', '/me'));
    return _account;
  }

  Future<void> updateName(String name) async => _setAccount(await api.call('PATCH', '/me', body: {'name': name}));

  /// [current] is required when changing an existing password, except right
  /// after signing in with an email code (forgot-password flow).
  Future<void> setPassword(String newPassword, {String? current}) async {
    await api.call('POST', '/me/password', body: {'new_password': newPassword, 'current_password': ?current});
    await refreshAccount();
  }

  Future<List<Map<String, dynamic>>> sessions() async =>
      ((await api.call('GET', '/me/sessions'))['sessions'] as List).cast<Map<String, dynamic>>();

  Future<void> revokeSession(String id) => api.call('DELETE', '/me/sessions/$id');

  Future<void> signOut() async {
    try {
      if (_refresh != null) await api.call('POST', '/auth/logout');
    } catch (_) {
      // offline / already revoked: still sign out locally
    }
    await _clear();
  }

  /// Deletes the account and everything synced (App Store requirement).
  Future<void> deleteAccount() async {
    await api.call('DELETE', '/me', body: {'confirm': _account!.email});
    await _clear();
  }

  Future<void> _clear() async {
    final was = _refresh != null || _account != null;
    _access = _refresh = null;
    _accessExp = null;
    _account = null;
    await _secure.delete(key: _kRefresh);
    await _prefs.remove(_kAccount);
    if (was) {
      for (final f in onSignedOut) {
        await f();
      }
    }
    notifyListeners();
  }
}
