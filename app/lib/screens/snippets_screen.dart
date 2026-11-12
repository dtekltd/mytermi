import 'package:flutter/material.dart';

import '../models/snippet.dart';
import '../services/command_store.dart';
import '../theme.dart';
import '../util/ids.dart';
import '../util/snippet_keys.dart';
import '../widgets/common.dart';

class SnippetsScreen extends StatelessWidget {
  const SnippetsScreen({super.key, required this.store, this.standalone = false});
  final CommandStore store;

  /// Pushed as its own route (shows a back button) rather than a home tab.
  final bool standalone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final body = SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final list = store.snippets;
          return Column(children: [
            PageHeader(
              title: 'Snippets',
              subtitle: '${list.length} ${list.length == 1 ? 'command' : 'commands'}',
              leading: standalone
                  ? CircleButton(icon: Icons.chevron_left, onPressed: () => Navigator.pop(context))
                  : null,
              actions: [
                CircleButton(icon: Icons.add, tooltip: 'Add snippet', onPressed: () => editSnippet(context, store)),
              ],
            ),
            Expanded(
              child: list.isEmpty
                  ? EmptyState(
                      icon: Icons.bolt_outlined,
                      text: 'Snippets are frequently used commands you can run with a single tap.\n\n'
                          'e.g. "View nginx log" → sudo tail -f /var/log/nginx/error.log',
                      action: FilledButton.icon(
                        onPressed: () => editSnippet(context, store),
                        icon: const Icon(Icons.add),
                        label: const Text('Add snippet'),
                      ),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.only(bottom: 120),
                      itemCount: list.length,
                      // Desktop would add its own handle next to ours.
                      buildDefaultDragHandles: false,
                      onReorderItem: store.reorderSnippet,
                      itemBuilder: (context, i) {
                        final s = list[i];
                        return Dismissible(
                          key: ValueKey(s.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 32),
                            child: Icon(Icons.delete, color: c.red),
                          ),
                          onDismissed: (_) => store.deleteSnippet(s),
                          child: ItemCard(
                            icon: snippetHasKeys(s.command)
                                ? Icons.keyboard_alt_outlined
                                : s.autoRun
                                    ? Icons.bolt
                                    : Icons.short_text,
                            iconColor: c.snippet,
                            title: s.displayName,
                            subtitle: s.command.split('\n').first,
                            onTap: () => editSnippet(context, store, snippet: s),
                            trailing: ReorderableDragStartListener(
                              index: i,
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Icon(Icons.drag_handle, color: c.textDim),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]);
        },
      ),
    );
    return standalone ? Scaffold(body: body) : body;
  }
}

/// Opens the snippet editor. [initialCommand] prefills a new snippet
/// (e.g. "save this history command as a snippet").
Future<void> editSnippet(
  BuildContext context,
  CommandStore store, {
  Snippet? snippet,
  String? initialCommand,
}) =>
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _SnippetEditScreen(store: store, snippet: snippet, initialCommand: initialCommand),
    ));

class _SnippetEditScreen extends StatefulWidget {
  const _SnippetEditScreen({required this.store, this.snippet, this.initialCommand});
  final CommandStore store;
  final Snippet? snippet;
  final String? initialCommand;

  @override
  State<_SnippetEditScreen> createState() => _SnippetEditScreenState();
}

class _SnippetEditScreenState extends State<_SnippetEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.snippet?.name ?? '');
  late final _command = TextEditingController(text: widget.snippet?.command ?? widget.initialCommand ?? '');
  late bool _autoRun = widget.snippet?.autoRun ?? true;
  late bool _hasKeys = snippetHasKeys(_command.text);

  @override
  void initState() {
    super.initState();
    _command.addListener(() {
      final k = snippetHasKeys(_command.text);
      if (k != _hasKeys) setState(() => _hasKeys = k);
    });
  }

  /// Inserts [token] at the cursor (or replaces the selection).
  void _insert(String token) {
    final v = _command.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _command.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, token),
      // "{ctrl+}" leaves the cursor before the brace to type the key.
      selection: TextSelection.collapsed(offset: sel.start + token.length - (token.endsWith('+}') ? 1 : 0)),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    await widget.store.saveSnippet(Snippet(
      id: widget.snippet?.id ?? newId(),
      name: _name.text.trim(),
      command: _command.text.trimRight(),
      autoRun: _autoRun,
    ));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    await widget.store.deleteSnippet(widget.snippet!);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.snippet == null ? 'New snippet' : 'Edit snippet'),
        actions: [
          if (widget.snippet != null)
            IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Restart nginx'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _command,
              autofocus: widget.snippet == null && widget.initialCommand == null,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 3,
              maxLines: 10,
              style: const TextStyle(fontFamily: monoFont),
              decoration: InputDecoration(
                labelText: 'Command',
                hintText: 'sudo systemctl restart nginx',
                helperText: _hasKeys
                    ? 'Sent exactly as written, keys included. Add {enter} where Enter is needed.'
                    : 'Multiple lines = run each command in turn. Keys go in braces, e.g. {ctrl+b}d detaches tmux.',
                helperMaxLines: 2,
                alignLabelWithHint: true,
              ),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, token) in _keyChips)
                  ActionChip(
                    label: Text(label, style: const TextStyle(fontSize: 12.5)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _insert(token),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (!_hasKeys) SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Run immediately when selected'),
              subtitle: const Text('Presses Enter automatically. Turn off to edit the command before running it.'),
              value: _autoRun,
              onChanged: (v) => setState(() => _autoRun = v),
            ),
          ],
        ),
      ),
    );
  }
}

/// Quick-insert buttons in the snippet editor.
const _keyChips = [
  ('Ctrl+B', '{ctrl+b}'),
  ('Ctrl+C', '{ctrl+c}'),
  ('Ctrl+D', '{ctrl+d}'),
  ('Esc', '{esc}'),
  ('Enter', '{enter}'),
  ('Tab', '{tab}'),
  ('↑', '{up}'),
  ('↓', '{down}'),
  ('Ctrl+…', '{ctrl+}'),
];
