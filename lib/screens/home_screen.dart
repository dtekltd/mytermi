import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../theme.dart';
import 'connections_screen.dart';
import 'host_list_screen.dart';
import 'settings_screen.dart';
import 'snippets_screen.dart';
import 'terminal_screen.dart';

void openTerminal(BuildContext context, AppServices app) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => TerminalScreen(manager: app.sessions, hosts: app.hosts, commands: app.commands),
  ));
}

/// Tabs (Hosts / Connections / Snippets) with a floating pill nav bar.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});
  final AppServices app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      extendBody: true,
      body: IndexedStack(index: _tab, children: [
        HostListScreen(app: app),
        ConnectionsScreen(app: app),
        SnippetsScreen(store: app.commands),
        SettingsScreen(app: app),
      ]),
      bottomNavigationBar: ListenableBuilder(
        listenable: app.sessions,
        builder: (context, _) => _PillNavBar(
          index: _tab,
          onChanged: (i) => setState(() => _tab = i),
          items: [
            (Icons.dns_rounded, 'Hosts', 0),
            (Icons.terminal_rounded, 'Connections', app.sessions.sessions.length),
            (Icons.bolt_rounded, 'Snippets', 0),
            (Icons.settings_rounded, 'Settings', 0),
          ],
        ),
      ),
    );
  }
}

class _PillNavBar extends StatelessWidget {
  const _PillNavBar({required this.index, required this.onChanged, required this.items});
  final int index;
  final ValueChanged<int> onChanged;
  final List<(IconData, String, int)> items; // icon, label, badge

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Center(
        heightFactor: 1,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(36),
            border: Border.all(color: c.border, width: 0.8),
            boxShadow: [BoxShadow(color: c.shadow, blurRadius: 20, offset: Offset(0, 6))],
          ),
          child: Row(children: [
            for (final (i, (icon, label, badge)) in items.indexed)
              Expanded(
                child: Material(
                  color: i == index ? c.bg : Colors.transparent,
                  borderRadius: BorderRadius.circular(30),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(30),
                    onTap: () => onChanged(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Badge(
                          isLabelVisible: badge > 0,
                          label: Text('$badge'),
                          backgroundColor: c.green,
                          textColor: c.bg,
                          child: Icon(icon, color: i == index ? c.green : c.text, size: 26),
                        ),
                        const SizedBox(height: 3),
                        Text(label,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: i == index ? c.text : c.textDim,
                            )),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
