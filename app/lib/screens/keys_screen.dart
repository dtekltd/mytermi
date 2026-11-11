import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ssh_key.dart';
import '../services/host_store.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Saved private keys. With [pick] true, tapping a key returns it (host editor).
class KeysScreen extends StatelessWidget {
  const KeysScreen({super.key, required this.store, this.pick = false, this.selectedId});
  final HostStore store;
  final bool pick;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(
        title: Text(pick ? 'Choose private key' : 'Private keys'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: 'Add key',
            onSelected: (v) async {
              final key = v == 'gen' ? await generateKeyFlow(context, store) : await importKeyFlow(context, store);
              if (key != null && pick && context.mounted) Navigator.pop(context, key);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'import',
                child: ListTile(leading: Icon(Icons.content_paste), title: Text('Import existing key')),
              ),
              PopupMenuItem(
                value: 'gen',
                child: ListTile(leading: Icon(Icons.auto_fix_high), title: Text('Generate new ED25519 key')),
              ),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final keys = store.keys;
          if (keys.isEmpty) {
            return EmptyState(
              icon: Icons.key_rounded,
              text: 'No private keys yet.\nImport an existing key or generate a new one, then choose it when adding a host.',
              action: Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Import key'),
                  onPressed: () async {
                    final k = await importKeyFlow(context, store);
                    if (k != null && pick && context.mounted) Navigator.pop(context, k);
                  },
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Generate key'),
                  onPressed: () async {
                    final k = await generateKeyFlow(context, store);
                    if (k != null && pick && context.mounted) Navigator.pop(context, k);
                  },
                ),
              ]),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 40),
            children: [
              for (final k in keys)
                ItemCard(
                  icon: Icons.key_rounded,
                  iconColor: c.blue,
                  title: k.label,
                  subtitle: '${k.typeLabel} · ${_usage(store.hostsUsingKey(k.id).length)}',
                  onTap: pick
                      ? () => Navigator.pop(context, k)
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => KeyDetailScreen(store: store, keyId: k.id)),
                          ),
                  trailing: pick
                      ? Icon(
                          k.id == selectedId ? Icons.check_circle : Icons.circle_outlined,
                          color: k.id == selectedId ? c.green : c.textDim,
                        )
                      : Icon(Icons.chevron_right, color: c.textDim),
                ),
              if (!pick)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Text(
                    'Private keys are stored encrypted in the Keychain (iOS) / Keystore (Android). '
                    'One key can be used for multiple hosts.',
                    style: TextStyle(color: c.textDim, fontSize: 13),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _usage(int n) => n == 0 ? 'unused' : 'used by $n ${n == 1 ? 'host' : 'hosts'}';
}

/// Paste an existing key. Returns the saved key, or null if cancelled.
Future<SshKey?> importKeyFlow(BuildContext context, HostStore store) =>
    Navigator.push<SshKey>(context, MaterialPageRoute(builder: (_) => KeyImportScreen(store: store)));

/// Ask for a name, generate an Ed25519 key, save it and show its public key.
Future<SshKey?> generateKeyFlow(BuildContext context, HostStore store) async {
  final label = await showTextInputDialog(
    context,
    title: 'Generate new ED25519 key',
    confirmText: 'Generate',
    initialText: 'mytermi',
    labelText: 'Key name',
    hintText: 'e.g. my-iphone',
  );
  if (label == null) return null;
  final pem = generateEd25519Pem(label.trim());
  final key = await store.addKey(label: label, pem: pem);
  if (context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => KeyDetailScreen(store: store, keyId: key.id, justCreated: true)),
    );
  }
  return key;
}

class KeyImportScreen extends StatefulWidget {
  const KeyImportScreen({super.key, required this.store});
  final HostStore store;

  @override
  State<KeyImportScreen> createState() => _KeyImportScreenState();
}

class _KeyImportScreenState extends State<KeyImportScreen> {
  final _form = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _pem = TextEditingController();
  final _passphrase = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_label, _pem, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validate(String? v) {
    try {
      parsePrivateKey(v ?? '', _passphrase.text);
      return null;
    } on KeyParseException catch (e) {
      return e.message;
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _pem.text = data!.text!.trim());
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final key = await widget.store.addKey(label: _label.text, pem: _pem.text, passphrase: _passphrase.text);
    if (mounted) Navigator.pop(context, key);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import private key'),
        actions: [TextButton(onPressed: _saving ? null : _save, child: const Text('Save'))],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Key name', hintText: 'e.g. macbook, aws-prod'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pem,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: monoFont, fontSize: 12),
              decoration: InputDecoration(
                labelText: 'Private key (OpenSSH / PEM)',
                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                alignLabelWithHint: true,
                suffixIcon: IconButton(
                  tooltip: 'Paste from clipboard',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _paste,
                ),
              ),
              validator: _validate,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passphrase,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Passphrase (if any)',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Supports ED25519, RSA and ECDSA (OpenSSH or PEM format). '
              'Keys are stored encrypted in the Keychain / Keystore.',
              style: TextStyle(color: context.colors.textDim, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Key info: rename, copy public key / install command, hosts using it, delete.
class KeyDetailScreen extends StatefulWidget {
  const KeyDetailScreen({super.key, required this.store, required this.keyId, this.justCreated = false});
  final HostStore store;
  final String keyId;
  final bool justCreated;

  @override
  State<KeyDetailScreen> createState() => _KeyDetailScreenState();
}

class _KeyDetailScreenState extends State<KeyDetailScreen> {
  late final TextEditingController _label;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.store.keyById(widget.keyId)?.label ?? '');
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _copy(String text, String msg) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _delete(SshKey key) async {
    final used = widget.store.hostsUsingKey(key.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete key "${key.label}"?'),
        content: Text(used.isEmpty
            ? 'The key will be removed from this device.'
            : 'These hosts use this key and will need a different one:\n'
                '${used.map((h) => '• ${h.displayName}').join('\n')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.deleteKey(key);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final key = widget.store.keyById(widget.keyId);
        if (key == null) return const Scaffold();
        final used = widget.store.hostsUsingKey(key.id);
        final installCmd = "mkdir -p ~/.ssh && echo '${key.publicKey}' >> ~/.ssh/authorized_keys"
            ' && chmod 600 ~/.ssh/authorized_keys';
        final mono = TextStyle(fontFamily: monoFont, fontSize: 12.5, color: c.text, height: 1.35);
        return Scaffold(
          appBar: AppBar(title: Text(key.label)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              if (widget.justCreated)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: c.greenBg, borderRadius: BorderRadius.circular(14)),
                  child: Text(
                    'Key generated. Add the public key below to ~/.ssh/authorized_keys on the server '
                    '(or paste the "install command" into a session logged in with a password), '
                    'then choose this key for the host.',
                    style: TextStyle(color: c.text, height: 1.4),
                  ),
                ),
              TextField(
                controller: _label,
                decoration: const InputDecoration(labelText: 'Key name'),
                onSubmitted: (v) => widget.store.renameKey(key, v),
                onTapOutside: (_) {
                  FocusScope.of(context).unfocus();
                  if (_label.text.trim() != key.label) widget.store.renameKey(key, _label.text);
                },
              ),
              const SectionLabel('Details'),
              _InfoRow(label: 'Type', value: key.typeLabel),
              _InfoRow(label: 'Fingerprint', value: key.fingerprint, mono: true),
              const SectionLabel('Public key'),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(14)),
                child: SelectableText(key.publicKey, style: mono),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Public key'),
                    onPressed: () => _copy(key.publicKey, 'Public key copied'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.terminal, size: 18),
                    label: const Text('Install command'),
                    onPressed: () => _copy(installCmd, 'Copied command that adds the key to authorized_keys'),
                  ),
                ),
              ]),
              const SectionLabel('Used by hosts'),
              if (used.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('No hosts use this key yet.', style: TextStyle(color: c.textDim)),
                )
              else
                for (final h in used)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: const Icon(Icons.dns_rounded),
                    title: Text(h.displayName),
                    subtitle: Text(h.address, style: TextStyle(color: c.textDim)),
                  ),
              const SizedBox(height: 28),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.red,
                  side: BorderSide(color: c.red.withValues(alpha: 0.5)),
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete key'),
                onPressed: () => _delete(key),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.mono = false});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 100, child: Text(label, style: TextStyle(color: c.textDim))),
        Expanded(
          child: SelectableText(
            value,
            style: mono ? TextStyle(fontFamily: monoFont, fontSize: 12.5, color: c.text) : null,
          ),
        ),
      ]),
    );
  }
}
