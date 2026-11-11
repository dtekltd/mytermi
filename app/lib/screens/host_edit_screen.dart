import 'package:flutter/material.dart';

import '../models/host.dart';
import '../models/ssh_key.dart';
import '../services/host_store.dart';
import '../theme.dart';
import 'keys_screen.dart';
import '../util/ids.dart';

class HostEditScreen extends StatefulWidget {
  const HostEditScreen({super.key, required this.store, this.host});
  final HostStore store;
  final Host? host;

  @override
  State<HostEditScreen> createState() => _HostEditScreenState();
}

class _HostEditScreenState extends State<HostEditScreen> {
  final _form = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _hostname = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _keyId;
  AuthMethod _auth = AuthMethod.password;
  bool _obscure = true;
  bool _saving = false;

  bool get _isEdit => widget.host != null;

  @override
  void initState() {
    super.initState();
    final h = widget.host;
    if (h != null) {
      _label.text = h.label;
      _hostname.text = h.hostname;
      _port.text = '${h.port}';
      _username.text = h.username;
      _auth = h.auth;
      _keyId = widget.store.keyById(h.keyId)?.id;
      widget.store.secretsFor(h).then((s) {
        if (mounted) setState(() => _password.text = s.password ?? '');
      });
    } else if (widget.store.keys.length == 1) {
      _keyId = widget.store.keys.first.id; // only one key: preselect it
    }
  }

  @override
  void dispose() {
    for (final c in [_label, _hostname, _port, _username, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickKey(FormFieldState<String> field) async {
    final key = await Navigator.push<SshKey>(
      context,
      MaterialPageRoute(builder: (_) => KeysScreen(store: widget.store, pick: true, selectedId: _keyId)),
    );
    if (key == null) return;
    setState(() => _keyId = key.id);
    field.didChange(key.id);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final host = Host(
      id: widget.host?.id ?? newId(),
      label: _label.text.trim(),
      hostname: _hostname.text.trim(),
      port: int.parse(_port.text.trim()),
      username: _username.text.trim(),
      auth: _auth,
      keyId: _auth == AuthMethod.key ? _keyId : null,
    );
    await widget.store.save(host, HostSecrets(password: _password.text));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit host' : 'Add host'),
        actions: [
          TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Display name (optional)', hintText: 'e.g. Ubuntu prod'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _hostname,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Host / IP'),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                    validator: (v) {
                      final p = int.tryParse((v ?? '').trim());
                      return (p == null || p < 1 || p > 65535) ? 'Sai' : null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username', hintText: 'ubuntu'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 20),
            SegmentedButton<AuthMethod>(
              segments: const [
                ButtonSegment(value: AuthMethod.password, label: Text('Password'), icon: Icon(Icons.password)),
                ButtonSegment(value: AuthMethod.key, label: Text('Private key'), icon: Icon(Icons.key)),
              ],
              selected: {_auth},
              onSelectionChanged: (s) => setState(() => _auth = s.first),
            ),
            const SizedBox(height: 16),
            if (_auth == AuthMethod.password)
              TextFormField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: 'Leave empty to enter it on each connection',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              )
            else
              FormField<String>(
                initialValue: _keyId,
                validator: (_) => _keyId == null ? 'Choose a private key' : null,
                builder: (field) {
                  final k = widget.store.keyById(_keyId);
                  return _KeyPickerTile(
                    keyLabel: k?.label,
                    keyInfo: k == null ? null : '${k.typeLabel} · ${k.fingerprint}',
                    error: field.errorText,
                    onTap: () => _pickKey(field),
                  );
                },
              ),
            const SizedBox(height: 24),
            Text(
              'Passwords and private keys are stored encrypted in the Keychain (iOS) / Keystore (Android). '
              'Manage keys in Settings › Private keys.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Private key: NAME" row that opens the key picker.
class _KeyPickerTile extends StatelessWidget {
  const _KeyPickerTile({this.keyLabel, this.keyInfo, this.error, required this.onTap});
  final String? keyLabel;
  final String? keyInfo;
  final String? error;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: error == null ? null : Border.all(color: c.red, width: 1.2),
            ),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: c.blue, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.key_rounded, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(keyLabel ?? 'Choose private key',
                      style: TextStyle(fontSize: 16, color: keyLabel == null ? c.textDim : c.text)),
                  if (keyInfo != null)
                    Text(keyInfo!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: monoFont, fontSize: 11.5, color: c.textDim)),
                ]),
              ),
              Icon(Icons.chevron_right, color: c.textDim),
            ]),
          ),
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 0, 0),
          child: Text(error!, style: TextStyle(color: c.red, fontSize: 12)),
        ),
    ]);
  }
}
