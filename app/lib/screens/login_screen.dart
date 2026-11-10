import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../env.dart';
import '../services/account_service.dart';
import '../services/api_client.dart';
import '../services/app_services.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'account_screen.dart';

String _friendly(Object e) => e is ApiException ? e.friendly : 'Có lỗi xảy ra: $e';

/// After any successful sign-in: optional password step, then the account page.
Future<void> _afterSignIn(BuildContext context, AppServices app, SignInResult r, {bool forgot = false}) async {
  final nav = Navigator.of(context);
  if (forgot || !r.account.hasPassword) {
    await nav.push(
      MaterialPageRoute(
        builder: (_) => SetPasswordScreen(app: app, mode: forgot ? PasswordMode.reset : PasswordMode.create),
      ),
    );
  }
  nav.popUntil((route) => route.isFirst);
  nav.push(MaterialPageRoute(builder: (_) => AccountScreen(app: app)));
}

/// Sign in or sign up: Apple, Google, email code, or email + password.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.app, this.config});
  final AppServices app;

  /// Skips fetching /config (tests, screenshots).
  final ServerConfig? config;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _withPassword = false;
  bool _busy = false;
  String? _error;
  ServerConfig? _config;
  String? _configError;

  AccountService get _acct => widget.app.account;

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    if (_config == null) _loadConfig();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() => _configError = null);
    if (_acct.serverUrl.isEmpty) {
      setState(() => _configError = 'Chưa đặt địa chỉ máy chủ đồng bộ.');
      return;
    }
    try {
      final c = await _acct.fetchConfig();
      if (mounted) setState(() => _config = c);
    } catch (e) {
      if (mounted) setState(() => _configError = _friendly(e));
    }
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _validEmail() {
    final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim());
    if (!ok) setState(() => _error = 'Nhập email hợp lệ.');
    return ok;
  }

  void _emailCode({bool forgot = false}) {
    if (!_validEmail()) return;
    _run(() async {
      await _acct.startEmail(_email.text);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OtpScreen(app: widget.app, email: _email.text.trim(), forgot: forgot),
        ),
      );
    });
  }

  void _passwordLogin() {
    if (!_validEmail()) return;
    _run(() async {
      final r = await _acct.signInWithPassword(_email.text, _password.text);
      if (mounted) await _afterSignIn(context, widget.app, r);
    });
  }

  void _social(Future<SignInResult?> Function() fn) => _run(() async {
    final r = await fn();
    if (r != null && mounted) await _afterSignIn(context, widget.app, r);
  });

  Future<void> _editServer() async {
    final url = await showTextInputDialog(
      context,
      title: 'Máy chủ đồng bộ',
      confirmText: 'Lưu',
      initialText: _acct.serverUrl,
      hintText: 'https://sync.example.com',
    );
    if (url == null) return;
    await _acct.setServerUrl(url);
    _config = null;
    await _loadConfig();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cfg = _config;
    final showApple = (Platform.isIOS || Platform.isMacOS) && (cfg?.apple ?? false);
    final showGoogle = (cfg?.google ?? false) && (Platform.isAndroid || googleIosClientId.isNotEmpty);
    return Scaffold(
      appBar: AppBar(title: const Text('Tài khoản')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Icon(Icons.cloud_sync_rounded, size: 56, color: c.green),
          const SizedBox(height: 12),
          const Text(
            'Đăng nhập hoặc đăng ký',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Đồng bộ host, private key và snippet giữa các thiết bị. Dữ liệu được mã hoá đầu-cuối: '
            'máy chủ không thể đọc được.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, height: 1.4),
          ),
          const SizedBox(height: 24),
          if (_configError != null)
            _Banner(
              text: _configError!,
              action: TextButton(onPressed: _loadConfig, child: const Text('Thử lại')),
            ),
          if (cfg != null && !cfg.signupEnabled)
            const _Banner(text: 'Máy chủ đang tạm dừng đăng ký mới. Tài khoản đã có vẫn đăng nhập được.'),
          if (showApple) ...[
            SizedBox(
              height: 50,
              child: SignInWithAppleButton(
                text: 'Tiếp tục với Apple',
                style: c.isDark ? SignInWithAppleButtonStyle.white : SignInWithAppleButtonStyle.black,
                borderRadius: const BorderRadius.all(Radius.circular(14)),
                onPressed: _busy ? () {} : () => _social(_acct.signInWithApple),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (showGoogle) ...[
            _BigButton(
              onPressed: _busy ? null : () => _social(_acct.signInWithGoogle),
              icon: const Text(
                'G',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF4285F4)),
              ),
              label: 'Tiếp tục với Google',
            ),
            const SizedBox(height: 12),
          ],
          if (showApple || showGoogle)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('hoặc', style: TextStyle(color: c.textDim)),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
            ),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            textInputAction: _withPassword ? TextInputAction.next : TextInputAction.go,
            onSubmitted: (_) => _withPassword ? null : _emailCode(),
            decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
          ),
          if (_withPassword) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _passwordLogin(),
              decoration: const InputDecoration(labelText: 'Mật khẩu', prefixIcon: Icon(Icons.lock_outline)),
            ),
          ],
          if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: TextStyle(color: c.red))],
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: _busy || cfg == null ? null : (_withPassword ? _passwordLogin : _emailCode),
              style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : Text(_withPassword ? 'Đăng nhập' : 'Tiếp tục với email', style: const TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 6),
          if (!_withPassword)
            Text(
              'Chúng tôi sẽ gửi mã 6 số tới email để đăng nhập hoặc tạo tài khoản.',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textDim, fontSize: 13),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _withPassword = !_withPassword;
                  _error = null;
                }),
                child: Text(_withPassword ? 'Dùng mã qua email' : 'Đăng nhập bằng mật khẩu'),
              ),
              if (_withPassword)
                TextButton(
                  onPressed: _busy ? null : () => _emailCode(forgot: true),
                  child: const Text('Quên mật khẩu?'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: _editServer,
              icon: Icon(Icons.dns_outlined, size: 18, color: c.textDim),
              label: Text(
                'Máy chủ: ${_acct.serverUrl.isEmpty ? 'chưa đặt' : Uri.tryParse(_acct.serverUrl)?.authority ?? _acct.serverUrl}',
                style: TextStyle(color: c.textDim),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(color: c.amber.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: TextStyle(color: c.text)),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.onPressed, required this.icon, required this.label});
  final VoidCallback? onPressed;
  final Widget icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 50,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: c.surface,
          foregroundColor: c.text,
          side: BorderSide(color: c.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// Enter the 6-digit code sent by email.
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.app, required this.email, this.forgot = false});
  final AppServices app;
  final String email;
  final bool forgot;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _code = TextEditingController();
  Timer? _timer;
  int _wait = 60;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _wait = 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _wait--);
      if (_wait <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.app.account.verifyEmail(widget.email, code);
      if (mounted) await _afterSignIn(context, widget.app, r, forgot: widget.forgot);
    } catch (e) {
      if (mounted) {
        setState(() => _error = _friendly(e));
        _code.clear();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    setState(() => _error = null);
    try {
      await widget.app.account.startEmail(widget.email);
      if (!mounted) return;
      _startTimer();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã gửi mã mới')));
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('Nhập mã xác thực')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Mã 6 số đã được gửi tới\n'),
                TextSpan(
                  text: widget.email,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: monoFont, fontSize: 32, letterSpacing: 12, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(hintText: '••••••', counterText: ''),
            onChanged: (v) {
              if (v.length == 6) _verify();
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.red),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: _busy ? null : _verify,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : const Text('Xác nhận', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _wait > 0 ? null : _resend,
            child: Text(_wait > 0 ? 'Gửi lại mã sau ${_wait}s' : 'Gửi lại mã'),
          ),
          Text(
            'Không thấy email? Kiểm tra thư mục Spam.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

enum PasswordMode { create, reset, change }

/// Set / reset / change the sign-in password.
class SetPasswordScreen extends StatefulWidget {
  const SetPasswordScreen({super.key, required this.app, required this.mode});
  final AppServices app;
  final PasswordMode mode;

  @override
  State<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<SetPasswordScreen> {
  final _current = TextEditingController();
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_current, _pw, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_pw.text.length < 8) return setState(() => _error = 'Mật khẩu cần ít nhất 8 ký tự.');
    if (_pw.text != _confirm.text) return setState(() => _error = 'Hai mật khẩu không khớp.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.account.setPassword(
        _pw.text,
        current: widget.mode == PasswordMode.change ? _current.text : null,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã lưu mật khẩu')));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (title, intro) = switch (widget.mode) {
      PasswordMode.create => (
        'Đặt mật khẩu',
        'Đặt mật khẩu để lần sau đăng nhập bằng email + mật khẩu (không cần chờ mã). Bạn có thể bỏ qua và làm sau.',
      ),
      PasswordMode.reset => ('Đặt mật khẩu mới', 'Nhập mật khẩu mới cho tài khoản.'),
      PasswordMode.change => ('Đổi mật khẩu', 'Nhập mật khẩu hiện tại và mật khẩu mới.'),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.mode == PasswordMode.create)
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Bỏ qua')),
        ],
      ),
      body: AutofillGroup(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(intro, style: TextStyle(color: c.textDim, height: 1.4)),
            const SizedBox(height: 20),
            if (widget.mode == PasswordMode.change) ...[
              TextField(
                controller: _current,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Mật khẩu hiện tại'),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _pw,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: 'Mật khẩu mới',
                helperText: 'Ít nhất 8 ký tự',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(labelText: 'Nhập lại mật khẩu mới'),
            ),
            if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: TextStyle(color: c.red))],
            const SizedBox(height: 20),
            SizedBox(
              height: 50,
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Lưu mật khẩu', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
