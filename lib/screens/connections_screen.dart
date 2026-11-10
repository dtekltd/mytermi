import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/session_manager.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'home_screen.dart';

/// Open sessions; tap to jump back into one.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key, required this.app});
  final AppServices app;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = app.sessions;
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: m,
        builder: (context, _) {
          final list = m.sessions;
          return Column(children: [
            PageHeader(title: 'Connections', subtitle: '${list.length} đang mở'),
            Expanded(
              child: list.isEmpty
                  ? const EmptyState(
                      icon: Icons.terminal_rounded,
                      text: 'Chưa có kết nối nào.\nChọn một host ở tab Hosts để bắt đầu.',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 120),
                      children: [
                        for (final s in list)
                          ItemCard(
                            icon: Icons.terminal_rounded,
                            iconColor: switch (s.status) {
                              SessionStatus.connected => c.green,
                              SessionStatus.disconnected => c.red,
                              _ => c.amber,
                            },
                            title: m.titleOf(s),
                            subtitle: '${s.host.address} · ${switch (s.status) {
                              SessionStatus.connected => 'đang kết nối',
                              SessionStatus.disconnected => 'đã ngắt',
                              _ => 'đang kết nối…',
                            }}',
                            onTap: () {
                              m.activate(s);
                              openTerminal(context, app);
                            },
                            trailing: IconButton(
                              tooltip: 'Đóng',
                              icon: Icon(Icons.close, color: c.textDim),
                              onPressed: () => m.close(s),
                            ),
                          ),
                      ],
                    ),
            ),
          ]);
        },
      ),
    );
  }
}
