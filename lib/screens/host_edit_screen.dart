import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/host.dart';
import '../services/host_store.dart';
import '../theme.dart';
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
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
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
      widget.store.secretsFor(h).then((s) {
        if (!mounted) return;
        setState(() {
          _password.text = s.password ?? '';
          _privateKey.text = s.privateKey ?? '';
          _passphrase.text = s.passphrase ?? '';
        });
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_label, _hostname, _port, _username, _password, _privateKey, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validateKey(String? v) {
    if (_auth != AuthMethod.key) return null;
    final pem = (v ?? '').trim();
    if (pem.isEmpty) return 'Dán private key vào đây';
    try {
      final pp = _passphrase.text.isEmpty ? null : _passphrase.text;
      if (SSHKeyPair.isEncryptedPem(pem) && pp == null) {
        return 'Key đã mã hoá, nhập passphrase bên dưới';
      }
      SSHKeyPair.fromPem(pem, pp);
    } catch (e) {
      return 'Key không hợp lệ hoặc sai passphrase';
    }
    return null;
  }

  Future<void> _pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _privateKey.text = data!.text!.trim());
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
    );
    await widget.store.save(
      host,
      HostSecrets(
        password: _password.text,
        privateKey: '${_privateKey.text.trim()}\n',
        passphrase: _passphrase.text,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Sửa host' : 'Thêm host'),
        actions: [
          TextButton(onPressed: _saving ? null : _save, child: const Text('Lưu')),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Tên hiển thị (tuỳ chọn)', hintText: 'VD: Ubuntu prod'),
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
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Bắt buộc' : null,
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
              validator: (v) => (v ?? '').trim().isEmpty ? 'Bắt buộc' : null,
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
                  helperText: 'Để trống nếu muốn nhập mỗi lần kết nối',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              )
            else ...[
              TextFormField(
                controller: _privateKey,
                maxLines: 6,
                autocorrect: false,
                style: const TextStyle(fontFamily: monoFont, fontSize: 12),
                decoration: InputDecoration(
                  labelText: 'Private key (OpenSSH / PEM)',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                  alignLabelWithHint: true,
                  suffixIcon: IconButton(
                    tooltip: 'Dán từ clipboard',
                    icon: const Icon(Icons.content_paste),
                    onPressed: _pasteKey,
                  ),
                ),
                validator: _validateKey,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphrase,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Passphrase (nếu có)'),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Password và private key được lưu mã hoá trong Keychain (iOS) / Keystore (Android).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
