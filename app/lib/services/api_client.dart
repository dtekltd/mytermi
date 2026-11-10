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
        'network' => 'Không kết nối được tới máy chủ. Kiểm tra mạng hoặc địa chỉ máy chủ.',
        'invalid_email' => 'Email không hợp lệ.',
        'invalid_code' => 'Mã không đúng hoặc đã hết hạn.',
        'invalid_credentials' => 'Sai email hoặc mật khẩu.',
        'weak_password' => 'Mật khẩu cần ít nhất 8 ký tự.',
        'rate_limited' => 'Thử quá nhiều lần. Vui lòng đợi ${details['retry_after'] ?? 60} giây.',
        'email_not_configured' => 'Máy chủ chưa cấu hình gửi email.',
        'email_send_failed' => 'Máy chủ không gửi được email. Thử lại sau.',
        'signup_disabled' => 'Máy chủ đang tạm dừng đăng ký tài khoản mới.',
        'account_disabled' => 'Tài khoản đã bị khoá.',
        'device_limit' =>
          'Gói ${details['plan'] ?? ''} chỉ cho phép ${details['max_devices'] ?? ''} thiết bị. Đăng xuất trên thiết bị khác hoặc nâng cấp gói.',
        'provider_not_configured' => 'Máy chủ chưa bật phương thức đăng nhập này.',
        'invalid_id_token' => 'Không xác thực được tài khoản. Thử lại.',
        'email_unverified' => 'Tài khoản này chưa có email đã xác minh.',
        'session_revoked' || 'unauthorized' => 'Phiên đăng nhập đã hết. Vui lòng đăng nhập lại.',
        'sync_disabled' => 'Gói hiện tại không bao gồm đồng bộ.',
        'vault_generation' => 'Vault đã được reset trên thiết bị khác. Hãy mở khoá lại.',
        'last_admin' => 'Không thể xoá tài khoản admin cuối cùng.',
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
