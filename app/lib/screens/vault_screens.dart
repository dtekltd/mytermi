import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/app_services.dart';
import '../services/vault_crypto.dart';
import '../theme.dart';

String _friendly(Object e) => switch (e) {
  ApiException() => e.friendly,
  VaultDecryptException() => 'Sai mật khẩu vault.',
  FormatException() => 'Recovery key không đúng định dạng (32 ký tự).',
  _ => 'Có lỗi xảy ra: $e',
};

/// Common layout for the vault forms.
class _VaultForm extends StatelessWidget {
  const _VaultForm({required this.title, required this.intro, required this.children});
  final String title;
  final String intro;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Icon(Icons.shield_outlined, size: 48, color: c.green),
          const SizedBox(height: 12),
          Text(intro, style: TextStyle(color: c.textDim, height: 1.45)),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    );
  }
}

Widget _submit(bool busy, String label, VoidCallback? onPressed) => SizedBox(
  height: 50,
  child: FilledButton(
    onPressed: busy ? null : onPressed,
    child: busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
        : Text(label, style: const TextStyle(fontSize: 16)),
  ),
);

/// Two password fields with validation; reused by setup / change / recover.
class _NewPassword extends StatefulWidget {
  const _NewPassword({required this.pw, required this.confirm, this.label = 'Mật khẩu vault'});
  final TextEditingController pw;
  final TextEditingController confirm;
  final String label;

  @override
  State<_NewPassword> createState() => _NewPasswordState();
}

class _NewPasswordState extends State<_NewPassword> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: widget.pw,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: widget.label,
            helperText: 'Ít nhất 8 ký tự. Nên khác mật khẩu đăng nhập.',
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: widget.confirm,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: 'Nhập lại ${widget.label.toLowerCase()}'),
        ),
      ],
    );
  }
}

String? _checkNew(TextEditingController pw, TextEditingController confirm) {
  if (pw.text.length < 8) return 'Mật khẩu vault cần ít nhất 8 ký tự.';
  if (pw.text != confirm.text) return 'Hai mật khẩu không khớp.';
  return null;
}

mixin _Busy<T extends StatefulWidget> on State<T> {
  bool busy = false;
  String? error;

  Future<void> run(Future<void> Function() fn) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => error = _friendly(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget errorText(BuildContext context) => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(error!, style: TextStyle(color: context.colors.red)),
        );
}

/// First device: choose a vault password, then show the recovery key.
class VaultSetupScreen extends StatefulWidget {
  const VaultSetupScreen({super.key, required this.app});
  final AppServices app;

  @override
  State<VaultSetupScreen> createState() => _VaultSetupScreenState();
}

class _VaultSetupScreenState extends State<VaultSetupScreen> with _Busy {
  final _pw = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _pw.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _create() {
    final bad = _checkNew(_pw, _confirm);
    if (bad != null) return setState(() => error = bad);
    run(() async {
      final recovery = await widget.app.sync.enable(_pw.text);
      if (!mounted) return;
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => RecoveryKeyScreen(recoveryKey: recovery)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return _VaultForm(
      title: 'Bật đồng bộ',
      intro:
          'Dữ liệu (host, private key, password SSH, snippet) được mã hoá ngay trên máy bằng mật khẩu vault '
          'trước khi gửi lên máy chủ. Máy chủ và quản trị viên không đọc được.\n\n'
          'Mật khẩu vault không gửi đi đâu cả, nên không thể lấy lại nếu quên. Bạn sẽ nhận một recovery key để dự phòng.',
      children: [
        _NewPassword(pw: _pw, confirm: _confirm),
        errorText(context),
        const SizedBox(height: 20),
        _submit(busy, 'Tạo vault & đồng bộ', _create),
      ],
    );
  }
}

/// Shows the recovery key once.
class RecoveryKeyScreen extends StatefulWidget {
  const RecoveryKeyScreen({super.key, required this.recoveryKey});
  final String recoveryKey;

  @override
  State<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends State<RecoveryKeyScreen> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopScope(
      canPop: _saved,
      child: Scaffold(
        appBar: AppBar(title: const Text('Recovery key'), automaticallyImplyLeading: false),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            Icon(Icons.key_rounded, size: 48, color: c.amber),
            const SizedBox(height: 12),
            Text(
              'Lưu recovery key ở nơi an toàn (trình quản lý mật khẩu, giấy cất kỹ). Đây là cách duy nhất '
              'để mở dữ liệu đồng bộ nếu bạn quên mật khẩu vault. Key chỉ hiện một lần.',
              style: TextStyle(color: c.textDim, height: 1.45),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.amber.withValues(alpha: 0.6)),
              ),
              child: SelectableText(
                widget.recoveryKey.replaceAllMapped(RegExp(r'((?:\w{4}-){3}\w{4})-'), (m) => '${m[1]}\n'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: monoFont, fontSize: 20, height: 1.6, letterSpacing: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Sao chép'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.recoveryKey));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã sao chép recovery key')));
              },
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              value: _saved,
              onChanged: (v) => setState(() => _saved = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('Tôi đã lưu recovery key'),
            ),
            const SizedBox(height: 8),
            _submit(false, 'Xong', _saved ? () => Navigator.pop(context) : null),
          ],
        ),
      ),
    );
  }
}

/// Another device: unlock with the vault password (or recovery key / reset).
class VaultUnlockScreen extends StatefulWidget {
  const VaultUnlockScreen({super.key, required this.app});
  final AppServices app;

  @override
  State<VaultUnlockScreen> createState() => _VaultUnlockScreenState();
}

class _VaultUnlockScreenState extends State<VaultUnlockScreen> with _Busy {
  final _pw = TextEditingController();

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  void _unlock() => run(() async {
    await widget.app.sync.unlock(_pw.text);
    if (mounted) Navigator.pop(context);
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _VaultForm(
      title: 'Mở khoá đồng bộ',
      intro: 'Nhập mật khẩu vault bạn đã đặt trên thiết bị đầu tiên. Máy này sẽ nhớ để không phải nhập lại.',
      children: [
        TextField(
          controller: _pw,
          obscureText: true,
          autofocus: true,
          autocorrect: false,
          onSubmitted: (_) => _unlock(),
          decoration: const InputDecoration(labelText: 'Mật khẩu vault'),
        ),
        errorText(context),
        const SizedBox(height: 20),
        _submit(busy, 'Mở khoá', _unlock),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => VaultRecoverScreen(app: widget.app)),
          ),
          child: const Text('Quên mật khẩu vault? Dùng recovery key'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: c.red),
          onPressed: () =>
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => VaultResetScreen(app: widget.app))),
          child: const Text('Mất cả hai? Reset đồng bộ'),
        ),
      ],
    );
  }
}

/// Unlock with the recovery key and choose a new vault password.
class VaultRecoverScreen extends StatefulWidget {
  const VaultRecoverScreen({super.key, required this.app});
  final AppServices app;

  @override
  State<VaultRecoverScreen> createState() => _VaultRecoverScreenState();
}

class _VaultRecoverScreenState extends State<VaultRecoverScreen> with _Busy {
  final _key = TextEditingController();
  final _pw = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    for (final c in [_key, _pw, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  void _go() {
    final bad = _checkNew(_pw, _confirm);
    if (bad != null) return setState(() => error = bad);
    run(() async {
      await widget.app.sync.recover(_key.text, _pw.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã mở khoá và đặt mật khẩu vault mới')));
      Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _VaultForm(
      title: 'Dùng recovery key',
      intro: 'Nhập recovery key (32 ký tự) rồi đặt mật khẩu vault mới. Các thiết bị khác vẫn tiếp tục đồng bộ.',
      children: [
        TextField(
          controller: _key,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          maxLines: 2,
          style: const TextStyle(fontFamily: monoFont),
          decoration: const InputDecoration(labelText: 'Recovery key', hintText: 'XXXX-XXXX-XXXX-…'),
        ),
        const SizedBox(height: 12),
        _NewPassword(pw: _pw, confirm: _confirm, label: 'Mật khẩu vault mới'),
        errorText(context),
        const SizedBox(height: 20),
        _submit(busy, 'Khôi phục', _go),
      ],
    );
  }
}

/// Last resort: delete the server vault and re-upload this device's data.
class VaultResetScreen extends StatefulWidget {
  const VaultResetScreen({super.key, required this.app});
  final AppServices app;

  @override
  State<VaultResetScreen> createState() => _VaultResetScreenState();
}

class _VaultResetScreenState extends State<VaultResetScreen> with _Busy {
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  bool _understood = false;

  @override
  void dispose() {
    _pw.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _reset() {
    final bad = _checkNew(_pw, _confirm);
    if (bad != null) return setState(() => error = bad);
    run(() async {
      final recovery = await widget.app.sync.resetVault(_pw.text);
      if (!mounted) return;
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => RecoveryKeyScreen(recoveryKey: recovery)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _VaultForm(
      title: 'Reset đồng bộ',
      intro:
          'Toàn bộ dữ liệu đồng bộ trên máy chủ sẽ bị xoá, rồi được tạo lại từ dữ liệu trên máy này với mật khẩu vault mới. '
          'Các thiết bị khác phải mở khoá lại bằng mật khẩu mới; dữ liệu chỉ có trên các thiết bị đó sẽ không được gộp vào.',
      children: [
        _NewPassword(pw: _pw, confirm: _confirm, label: 'Mật khẩu vault mới'),
        CheckboxListTile(
          value: _understood,
          onChanged: (v) => setState(() => _understood = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text('Tôi hiểu dữ liệu đồng bộ cũ sẽ bị xoá'),
        ),
        errorText(context),
        const SizedBox(height: 12),
        SizedBox(
          height: 50,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.red),
            onPressed: busy || !_understood ? null : _reset,
            child: busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Text('Xoá & tạo lại', style: TextStyle(fontSize: 16)),
          ),
        ),
      ],
    );
  }
}

/// Change the vault password (this device must be unlocked).
class VaultPasswordScreen extends StatefulWidget {
  const VaultPasswordScreen({super.key, required this.app});
  final AppServices app;

  @override
  State<VaultPasswordScreen> createState() => _VaultPasswordScreenState();
}

class _VaultPasswordScreenState extends State<VaultPasswordScreen> with _Busy {
  final _current = TextEditingController();
  final _pw = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    for (final c in [_current, _pw, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final bad = _checkNew(_pw, _confirm);
    if (bad != null) return setState(() => error = bad);
    run(() async {
      await widget.app.sync.changePassword(_current.text, _pw.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã đổi mật khẩu vault')));
      Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _VaultForm(
      title: 'Đổi mật khẩu vault',
      intro:
          'Thiết bị đang đồng bộ không bị ảnh hưởng. Thiết bị mới sẽ cần mật khẩu mới. Recovery key cũ vẫn dùng được.',
      children: [
        TextField(
          controller: _current,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Mật khẩu vault hiện tại'),
        ),
        const SizedBox(height: 12),
        _NewPassword(pw: _pw, confirm: _confirm, label: 'Mật khẩu vault mới'),
        errorText(context),
        const SizedBox(height: 20),
        _submit(busy, 'Lưu', _save),
      ],
    );
  }
}
