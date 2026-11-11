import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/app_services.dart';
import '../services/vault_crypto.dart';
import '../theme.dart';

String _friendly(Object e) => switch (e) {
  ApiException() => e.friendly,
  VaultDecryptException() => 'Wrong vault password.',
  FormatException() => 'Invalid recovery key format (32 characters).',
  _ => 'Something went wrong: $e',
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
  const _NewPassword({required this.pw, required this.confirm, this.label = 'Vault password'});
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
            helperText: 'At least 8 characters. Use a different one from your account password.',
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
          decoration: InputDecoration(labelText: 'Confirm ${widget.label.toLowerCase()}'),
        ),
      ],
    );
  }
}

String? _checkNew(TextEditingController pw, TextEditingController confirm) {
  if (pw.text.length < 8) return 'Vault password must be at least 8 characters.';
  if (pw.text != confirm.text) return 'Passwords don\'t match.';
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
      title: 'Turn on sync',
      intro:
          'Your data (hosts, private keys, SSH passwords, snippets) is encrypted on this device with your vault password '
          'before it is sent to the server. Neither the server nor its administrators can read it.\n\n'
          'Your vault password never leaves this device, so it can\'t be recovered if you forget it. You\'ll get a recovery key as a backup.',
      children: [
        _NewPassword(pw: _pw, confirm: _confirm),
        errorText(context),
        const SizedBox(height: 20),
        _submit(busy, 'Create vault & sync', _create),
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
              'Store your recovery key somewhere safe (a password manager, or on paper kept securely). It is the only way '
              'to unlock your synced data if you forget your vault password. It is shown only once.',
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
              label: const Text('Copy'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.recoveryKey));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recovery key copied')));
              },
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              value: _saved,
              onChanged: (v) => setState(() => _saved = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('I have saved my recovery key'),
            ),
            const SizedBox(height: 8),
            _submit(false, 'Done', _saved ? () => Navigator.pop(context) : null),
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
      title: 'Unlock sync',
      intro: 'Enter the vault password you set on your first device. This device will remember it so you don\'t have to enter it again.',
      children: [
        TextField(
          controller: _pw,
          obscureText: true,
          autofocus: true,
          autocorrect: false,
          onSubmitted: (_) => _unlock(),
          decoration: const InputDecoration(labelText: 'Vault password'),
        ),
        errorText(context),
        const SizedBox(height: 20),
        _submit(busy, 'Unlock', _unlock),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => VaultRecoverScreen(app: widget.app)),
          ),
          child: const Text('Forgot your vault password? Use your recovery key'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: c.red),
          onPressed: () =>
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => VaultResetScreen(app: widget.app))),
          child: const Text('Lost both? Reset sync'),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Unlocked and set a new vault password')));
      Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _VaultForm(
      title: 'Use recovery key',
      intro: 'Enter your recovery key (32 characters), then set a new vault password. Your other devices keep syncing.',
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
        _NewPassword(pw: _pw, confirm: _confirm, label: 'New vault password'),
        errorText(context),
        const SizedBox(height: 20),
        _submit(busy, 'Recover', _go),
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
      title: 'Reset sync',
      intro:
          'All synced data on the server will be deleted, then recreated from the data on this device with a new vault password. '
          'Your other devices must unlock again with the new password; data that exists only on those devices will not be merged in.',
      children: [
        _NewPassword(pw: _pw, confirm: _confirm, label: 'New vault password'),
        CheckboxListTile(
          value: _understood,
          onChanged: (v) => setState(() => _understood = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text('I understand the old synced data will be deleted'),
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
                : const Text('Delete & recreate', style: TextStyle(fontSize: 16)),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vault password changed')));
      Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _VaultForm(
      title: 'Change vault password',
      intro:
          'Devices that are already syncing are not affected. New devices will need the new password. Your existing recovery key still works.',
      children: [
        TextField(
          controller: _current,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Current vault password'),
        ),
        const SizedBox(height: 12),
        _NewPassword(pw: _pw, confirm: _confirm, label: 'New vault password'),
        errorText(context),
        const SizedBox(height: 20),
        _submit(busy, 'Save', _save),
      ],
    );
  }
}
