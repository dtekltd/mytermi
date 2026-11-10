import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../env.dart';
import '../services/app_services.dart';
import '../services/settings_store.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});
  final AppServices app;

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            const PageHeader(title: 'Settings', subtitle: 'MyTermi'),

            // ------------------------------------------------ appearance
            const SectionLabel('Giao diện'),
            _Group(children: [
              _Tile(
                icon: Icons.brightness_6_outlined,
                title: 'Chế độ hiển thị',
                below: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('Hệ thống')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Sáng')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Tối')),
                  ],
                  selected: {s.themeMode},
                  onSelectionChanged: (v) => s.themeMode = v.first,
                ),
              ),
              _Tile(
                icon: Icons.palette_outlined,
                title: 'Màu terminal',
                subtitle: 'Có thể giữ terminal tối khi app ở chế độ sáng',
                below: SegmentedButton<TerminalColors>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: TerminalColors.auto, label: Text('Theo app')),
                    ButtonSegment(value: TerminalColors.light, label: Text('Sáng')),
                    ButtonSegment(value: TerminalColors.dark, label: Text('Tối')),
                  ],
                  selected: {s.terminalColors},
                  onSelectionChanged: (v) => s.terminalColors = v.first,
                ),
              ),
            ]),

            // -------------------------------------------------- terminal
            const SectionLabel('Terminal'),
            _Group(children: [
              _Tile(
                icon: Icons.format_size,
                title: 'Cỡ chữ',
                trailing: Text('${s.fontSize.round()}', style: const TextStyle(fontSize: 16)),
                below: Slider(
                  min: SettingsStore.minFont,
                  max: SettingsStore.maxFont,
                  divisions: (SettingsStore.maxFont - SettingsStore.minFont).round(),
                  value: s.fontSize,
                  onChanged: (v) => s.fontSize = v,
                ),
              ),
              _Preview(fontSize: s.fontSize, colors: s.terminalColors, cursor: s.cursorType),
              _Tile(
                icon: Icons.text_fields,
                title: 'Kiểu con trỏ',
                below: SegmentedButton<TerminalCursorType>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: TerminalCursorType.block, label: Text('Khối')),
                    ButtonSegment(value: TerminalCursorType.underline, label: Text('Gạch dưới')),
                    ButtonSegment(value: TerminalCursorType.verticalBar, label: Text('Thanh')),
                  ],
                  selected: {s.cursorType},
                  onSelectionChanged: (v) => s.cursorType = v.first,
                ),
              ),
            ]),

            // -------------------------------------------------- gestures
            const SectionLabel('Thao tác'),
            _Group(children: [
              _Tile(
                icon: Icons.swipe,
                title: 'Độ nhạy vuốt mũi tên',
                subtitle: 'Cao = vuốt ngắn hơn cho mỗi lần bấm',
                below: SegmentedButton<SwipeSensitivity>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: SwipeSensitivity.low, label: Text('Thấp')),
                    ButtonSegment(value: SwipeSensitivity.medium, label: Text('Vừa')),
                    ButtonSegment(value: SwipeSensitivity.high, label: Text('Cao')),
                  ],
                  selected: {s.swipe},
                  onSelectionChanged: (v) => s.swipe = v.first,
                ),
              ),
              _Switch(
                icon: Icons.touch_app_outlined,
                title: 'Double tap = phím Tab',
                value: s.doubleTapTab,
                onChanged: (v) => s.doubleTapTab = v,
              ),
              _Switch(
                icon: Icons.vibration,
                title: 'Rung phản hồi',
                value: s.haptics,
                onChanged: (v) => s.haptics = v,
              ),
              _Switch(
                icon: Icons.logout,
                title: 'Hỏi trước khi đóng session',
                value: s.confirmClose,
                onChanged: (v) => s.confirmClose = v,
              ),
            ]),

            // --------------------------------------------------- history
            const SectionLabel('Gợi ý & lịch sử lệnh'),
            _Group(children: [
              _Switch(
                icon: Icons.auto_awesome_outlined,
                title: 'Gợi ý lệnh khi gõ',
                value: s.suggestions,
                onChanged: (v) => s.suggestions = v,
              ),
              _Switch(
                icon: Icons.history,
                title: 'Lưu lịch sử lệnh',
                subtitle: 'Chỉ lưu lệnh được server hiện lại — không bao giờ lưu password',
                value: s.saveHistory,
                onChanged: (v) => s.saveHistory = v,
              ),
            ]),

            // ------------------------------------------------- data
            const SectionLabel('Dữ liệu & bảo mật'),
            _Group(children: [
              _Tile(
                icon: Icons.delete_sweep_outlined,
                title: 'Xoá toàn bộ lịch sử lệnh',
                danger: true,
                onTap: () => _confirm(
                  context,
                  title: 'Xoá toàn bộ lịch sử lệnh?',
                  body: 'Lịch sử của tất cả host sẽ bị xoá. Snippet được giữ lại.',
                  action: () async {
                    await app.commands.clearAllHistory();
                    for (final x in app.sessions.sessions) {
                      x.refreshSuggestions();
                    }
                    return 'Đã xoá lịch sử lệnh';
                  },
                ),
              ),
              _Tile(
                icon: Icons.gpp_maybe_outlined,
                title: 'Quên các host key đã tin',
                subtitle: 'Lần kết nối sau sẽ hỏi lại fingerprint',
                danger: true,
                onTap: () => _confirm(
                  context,
                  title: 'Quên tất cả host key?',
                  body: 'Bạn sẽ phải xác nhận lại fingerprint khi kết nối tới từng server.',
                  action: () async => 'Đã xoá ${await app.hosts.clearKnownHosts()} host key',
                ),
              ),
            ]),

            const SectionLabel('Thông tin'),
            _Group(children: [
              _Tile(
                icon: Icons.info_outline,
                title: 'MyTermi',
                subtitle: 'SSH client · phiên bản 1.0.0${isProd ? '' : ' · $appEnv'}',
              ),
              const _Tile(
                icon: Icons.font_download_outlined,
                title: 'Font JetBrains Mono',
                subtitle: 'SIL Open Font License 1.1',
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required Future<String> Function() action,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok == true) messenger.showSnackBar(SnackBar(content: Text(await action())));
  }
}

/// Rounded card holding a group of settings rows.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (final (i, w) in children.indexed) ...[
          if (i > 0) Divider(indent: 56, height: 1, color: c.border.withValues(alpha: 0.6)),
          w,
        ],
      ]),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.below,
    this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? below; // full-width control under the title (segments, slider)
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = danger ? c.red : c.text;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, color: danger ? c.red : c.green, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 16, color: color)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: TextStyle(fontSize: 13, color: c.textDim)),
                  ),
              ]),
            ),
            ?trailing,
          ]),
          if (below != null) Padding(padding: const EdgeInsets.only(top: 10, left: 40), child: below),
        ]),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({required this.icon, required this.title, this.subtitle, required this.value, required this.onChanged});
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _Tile(
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: () => onChanged(!value),
        trailing: Switch.adaptive(value: value, onChanged: onChanged),
      );
}

/// Live sample of the terminal with the chosen font size / colours / cursor.
class _Preview extends StatelessWidget {
  const _Preview({required this.fontSize, required this.colors, required this.cursor});
  final double fontSize;
  final TerminalColors colors;
  final TerminalCursorType cursor;

  @override
  Widget build(BuildContext context) {
    final t = switch (colors) {
      TerminalColors.dark => terminalThemeDark,
      TerminalColors.light => terminalThemeLight,
      TerminalColors.auto => context.colors.isDark ? terminalThemeDark : terminalThemeLight,
    };
    final style = TextStyle(fontFamily: monoFont, fontSize: fontSize, color: t.foreground, height: 1.3);
    final cursorBox = switch (cursor) {
      TerminalCursorType.block => Container(width: fontSize * 0.6, height: fontSize * 1.2, color: t.cursor),
      TerminalCursorType.underline => Container(width: fontSize * 0.6, height: 2, color: t.cursor),
      TerminalCursorType.verticalBar => Container(width: 2, height: fontSize * 1.2, color: t.cursor),
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.background, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(style: style, children: [
          TextSpan(text: 'ubuntu', style: TextStyle(color: t.yellow)),
          const TextSpan(text: '@'),
          TextSpan(text: 'dev1', style: TextStyle(color: t.green, fontWeight: FontWeight.bold)),
          const TextSpan(text: ':'),
          TextSpan(text: '~/app', style: TextStyle(color: t.blue, fontWeight: FontWeight.bold)),
          const TextSpan(text: r'$ ls'),
        ])),
        Text.rich(TextSpan(style: style, children: [
          TextSpan(text: 'src  ', style: TextStyle(color: t.blue, fontWeight: FontWeight.bold)),
          TextSpan(text: 'run.sh  ', style: TextStyle(color: t.green)),
          const TextSpan(text: 'README.md'),
        ])),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(r'$ ', style: style),
          cursorBox,
        ]),
      ]),
    );
  }
}
