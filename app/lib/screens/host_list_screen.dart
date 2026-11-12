import 'package:flutter/material.dart';

import '../models/host.dart';
import '../services/app_services.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'home_screen.dart';
import 'host_edit_screen.dart';

class HostListScreen extends StatefulWidget {
  const HostListScreen({super.key, required this.app});
  final AppServices app;

  @override
  State<HostListScreen> createState() => _HostListScreenState();
}

class _HostListScreenState extends State<HostListScreen> {
  final _search = TextEditingController();
  String _q = '';

  AppServices get app => widget.app;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit([Host? host]) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HostEditScreen(store: app.hosts, host: host),
      ));

  Future<void> _clone(Host host) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HostEditScreen(store: app.hosts, cloneOf: host),
      ));

  /// Jump into the host's latest session if one is open, else start one.
  void _connect(Host host, {bool forceNew = false}) {
    final existing = app.sessions.forHost(host.id).toList();
    if (existing.isNotEmpty && !forceNew) {
      app.sessions.activate(existing.last);
    } else {
      app.sessions.open(host);
    }
    openTerminal(context, app);
  }

  Future<void> _confirmDelete(Host host) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete host?'),
        content: Text('Delete "${host.displayName}" along with its saved credentials and command history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    app.sessions.closeHost(host.id);
    await app.hosts.delete(host);
    await app.commands.clearHistory(host.id);
  }

  bool _matches(Host h) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return h.displayName.toLowerCase().contains(q) ||
        h.hostname.toLowerCase().contains(q) ||
        h.username.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: Listenable.merge([app.hosts, app.sessions]),
        builder: (context, _) {
          final all = app.hosts.hosts;
          final hosts = all.where(_matches).toList();
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                title: 'Hosts',
                subtitle: 'MyTermi',
                actions: [CircleButton(icon: Icons.add, tooltip: 'Add host', onPressed: _edit)],
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _SearchField(controller: _search, onChanged: (v) => setState(() => _q = v.trim())),
              ),
            ),
            const SliverToBoxAdapter(child: SectionLabel('Hosts')),
            if (all.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.dns_outlined,
                  text: 'No hosts yet.\nAdd your first SSH server.',
                  action: FilledButton.icon(onPressed: _edit, icon: const Icon(Icons.add), label: const Text('Add host')),
                ),
              )
            else if (_q.isEmpty)
              // Drag the handle to reorder, like Snippets. Not while searching:
              // indexes in a filtered list don't map onto the stored order.
              SliverReorderableList(
                itemCount: hosts.length,
                onReorderItem: app.hosts.reorderHost,
                itemBuilder: (context, i) => KeyedSubtree(key: ValueKey(hosts[i].id), child: _hostCard(hosts[i], i)),
              )
            else
              SliverList.list(children: [for (final h in hosts) _hostCard(h)]),
            if (all.isNotEmpty) const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ]);
        },
      ),
    );
  }

  /// [index] is set when the list is reorderable: the card then gets a drag handle.
  Widget _hostCard(Host h, [int? index]) {
    final c = context.colors;
    final active = app.sessions.forHost(h.id).length;
    return ItemCard(
      icon: h.auth == AuthMethod.key ? Icons.vpn_key_rounded : Icons.terminal_rounded,
      title: h.displayName,
      subtitle: active > 0 ? '$active active connection${active > 1 ? 's' : ''}' : 'ssh, ${h.username}',
      subtitleColor: active > 0 ? c.green : null,
      onTap: () => _connect(h),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (index != null)
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.drag_handle, color: c.textDim),
            ),
          ),
        _menu(h),
      ]),
    );
  }

  Widget _menu(Host h) {
    final c = context.colors;
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, color: c.text, size: 28),
      onSelected: (v) {
        switch (v) {
          case 'new':
            _connect(h, forceNew: true);
          case 'edit':
            _edit(h);
          case 'clone':
            _clone(h);
          case 'delete':
            _confirmDelete(h);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'new', child: ListTile(leading: Icon(Icons.add), title: Text('New session'))),
        const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit), title: Text('Edit'))),
        const PopupMenuItem(value: 'clone', child: ListTile(leading: Icon(Icons.copy), title: Text('Clone'))),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(leading: Icon(Icons.delete_outline, color: c.red), title: const Text('Delete')),
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide(color: c.border),
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 17),
      decoration: InputDecoration(
        hintText: 'Search',
        hintStyle: TextStyle(color: c.textDim, fontSize: 17),
        prefixIcon: Icon(Icons.search, color: c.text),
        fillColor: c.surfaceHi.withValues(alpha: 0.7),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: c.green)),
      ),
    );
  }
}
