import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Error returned by the MyTermi server: `{"error": {"code", "message"}}`.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, [this.details = const {}]);
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> details;

  /// Vietnamese text for the user.
  String get friendly => switch (code) {
        'network' => 'Couldn\'t reach the server. Check your network or the server URL.',
        'invalid_email' => 'Invalid email address.',
        'invalid_code' => 'The code is wrong or has expired.',
        'invalid_credentials' => 'Wrong email or password.',
        'weak_password' => 'Password must be at least 8 characters.',
        'rate_limited' => 'Too many attempts. Please wait ${details['retry_after'] ?? 60} seconds.',
        'email_not_configured' => 'The server isn\'t set up to send email.',
        'email_send_failed' => 'The server couldn\'t send the email. Try again later.',
        'signup_disabled' => 'The server isn\'t accepting new sign-ups right now.',
        'account_disabled' => 'This account has been disabled.',
        'device_limit' =>
          'The ${details['plan'] ?? ''} plan allows only ${details['max_devices'] ?? ''} devices. Sign out on another device or upgrade your plan.',
        'provider_not_configured' => 'This sign-in method isn\'t enabled on the server.',
        'invalid_id_token' => 'Couldn\'t verify your account. Try again.',
        'email_unverified' => 'This account doesn\'t have a verified email.',
        'session_revoked' || 'unauthorized' => 'Your session has expired. Please sign in again.',
        'sync_disabled' => 'Your plan doesn\'t include sync.',
        'vault_generation' => 'The vault was reset on another device. Unlock it again.',
        'last_admin' => 'You can\'t delete the last admin account.',
        _ => message,
      };

  @override
  String toString() => 'ApiException($status $code: $message)';
}

/// Stores tokens; implemented by AccountService (secure storage).
abstract interface class TokenStore {
  String? get accessToken;
  DateTime? get accessExpiry;
  String? get refreshToken;
  Future<void> saveTokens(String access, DateTime expiry, String refresh);
  Future<void> onSessionLost();
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.tokens, http.Client? client}) : _http = client ?? http.Client();

  String baseUrl; // e.g. https://sync.example.com
  final TokenStore tokens;
  final http.Client _http;
  Future<void>? _refreshing;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$base/api/v1$path').replace(queryParameters: query);
  }

  /// Unauthenticated call (sign-in endpoints).
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _send('POST', path, body: body, auth: false);

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query, bool auth = true}) =>
      _send('GET', path, query: query, auth: auth);

  /// Authenticated call; refreshes the access token when needed.
  Future<Map<String, dynamic>> call(String method, String path, {Object? body, Map<String, String>? query}) =>
      _send(method, path, body: body, query: query, auth: true);

  Future<Map<String, dynamic>> _send(String method, String path,
      {Object? body, Map<String, String>? query, required bool auth, bool retried = false}) async {
    if (auth) await _ensureAccess();
    final req = http.Request(method, _uri(path, query));
    req.headers['Accept'] = 'application/json';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    if (auth && tokens.accessToken != null) req.headers['Authorization'] = 'Bearer ${tokens.accessToken}';
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 30)));
    } on TimeoutException {
      throw ApiException(0, 'network', 'timeout');
    } catch (e) {
      throw ApiException(0, 'network', e.toString());
    }
    final data = res.body.isEmpty ? <String, dynamic>{} : _decode(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) return data;
    final err = (data['error'] as Map?)?.cast<String, dynamic>() ?? {};
    final ex = ApiException(res.statusCode, (err['code'] ?? 'http_${res.statusCode}') as String,
        (err['message'] ?? res.reasonPhrase ?? '') as String, (err['details'] as Map?)?.cast<String, dynamic>() ?? {});
    if (auth && !retried && ex.code == 'token_expired') {
      await _refresh(force: true);
      return _send(method, path, body: body, query: query, auth: auth, retried: true);
    }
    if (auth && (ex.code == 'session_revoked' || ex.code == 'unauthorized' || ex.code == 'account_disabled')) {
      await tokens.onSessionLost();
    }
    throw ex;
  }

  static Map<String, dynamic> _decode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : {'data': v};
    } catch (_) {
      return {};
    }
  }

  Future<void> _ensureAccess() async {
    final exp = tokens.accessExpiry;
    if (tokens.accessToken == null || exp == null || exp.isBefore(DateTime.now().add(const Duration(seconds: 30)))) {
      await _refresh();
    }
  }

  /// One refresh at a time; concurrent callers wait for it.
  Future<void> _refresh({bool force = false}) {
    return _refreshing ??= () async {
      try {
        final rt = tokens.refreshToken;
        if (rt == null) throw ApiException(401, 'unauthorized', 'not signed in');
        try {
          final r = await post('/auth/refresh', {'refresh_token': rt});
          await tokens.saveTokens(
              r['access_token'] as String, DateTime.parse(r['expires_at'] as String), r['refresh_token'] as String);
        } on ApiException catch (e) {
          if (e.status == 401 || e.status == 403) await tokens.onSessionLost();
          rethrow;
        }
      } finally {
        _refreshing = null;
      }
    }();
  }
}
