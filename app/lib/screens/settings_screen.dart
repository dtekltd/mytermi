import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../env.dart';
import '../services/app_services.dart';
import '../services/settings_store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/settings_tiles.dart';
import 'account_screen.dart';
import 'keys_screen.dart';
import 'login_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});
  final AppServices app;

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: Listenable.merge([s, app.hosts, app.account, app.sync]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            const PageHeader(title: 'Settings', subtitle: 'MyTermi'),

            // --------------------------------------------- account & sync
            const SectionLabel('Tài khoản & đồng bộ'),
            SettingsGroup(children: [
              if (app.account.account case final a?)
                SettingsTile(
                  icon: Icons.account_circle_outlined,
                  title: a.email,
                  subtitle: syncSummary(app.sync),
                  trailing: Icon(Icons.chevron_right, color: context.colors.textDim),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountScreen(app: app))),
                )
              else
                SettingsTile(
                  icon: Icons.cloud_sync_outlined,
                  title: 'Đăng nhập / Đăng ký',
                  subtitle: 'Đồng bộ host, key, snippet giữa các thiết bị (mã hoá đầu-cuối)',
                  trailing: Icon(Icons.chevron_right, color: context.colors.textDim),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LoginScreen(app: app))),
                ),
            ]),

            // ------------------------------------------------ appearance
            const SectionLabel('Giao diện'),
            SettingsGroup(
              children: [
                SettingsTile(
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
                SettingsTile(
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
              ],
            ),

            // -------------------------------------------------- terminal
            const SectionLabel('Terminal'),
            SettingsGroup(
              children: [
                SettingsTile(
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
                SettingsTile(
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
              ],
            ),

            // -------------------------------------------------- gestures
            const SectionLabel('Thao tác'),
            SettingsGroup(
              children: [
                SettingsTile(
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
                SettingsSwitch(
                  icon: Icons.touch_app_outlined,
                  title: 'Double tap = phím Tab',
                  value: s.doubleTapTab,
                  onChanged: (v) => s.doubleTapTab = v,
                ),
                SettingsSwitch(
                  icon: Icons.vibration,
                  title: 'Rung phản hồi',
                  value: s.haptics,
                  onChanged: (v) => s.haptics = v,
                ),
                SettingsSwitch(
                  icon: Icons.logout,
                  title: 'Hỏi trước khi đóng session',
                  value: s.confirmClose,
                  onChanged: (v) => s.confirmClose = v,
                ),
              ],
            ),

            // --------------------------------------------------- history
            const SectionLabel('Gợi ý & lịch sử lệnh'),
            SettingsGroup(
              children: [
                SettingsSwitch(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Gợi ý lệnh khi gõ',
                  value: s.suggestions,
                  onChanged: (v) => s.suggestions = v,
                ),
                SettingsSwitch(
                  icon: Icons.history,
                  title: 'Lưu lịch sử lệnh',
                  subtitle: 'Chỉ lưu lệnh được server hiện lại — không bao giờ lưu password',
                  value: s.saveHistory,
                  onChanged: (v) => s.saveHistory = v,
                ),
              ],
            ),

            // ------------------------------------------------- data
            const SectionLabel('Dữ liệu & bảo mật'),
            SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.key_rounded,
                  title: 'Private keys',
                  subtitle: 'Quản lý SSH key dùng chung cho các host',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${app.hosts.keys.length}', style: TextStyle(fontSize: 16, color: context.colors.textDim)),
                      Icon(Icons.chevron_right, color: context.colors.textDim),
                    ],
                  ),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => KeysScreen(store: app.hosts))),
                ),
                SettingsTile(
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
                SettingsTile(
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
              ],
            ),

            const SectionLabel('Thông tin'),
            SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.info_outline,
                  title: 'MyTermi',
                  subtitle: 'SSH client · phiên bản 1.0.0${isProd ? '' : ' · $appEnv'}',
                ),
                const SettingsTile(
                  icon: Icons.font_download_outlined,
                  title: 'Font JetBrains Mono',
                  subtitle: 'SIL Open Font License 1.1',
                ),
              ],
            ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: style,
              children: [
                TextSpan(
                  text: 'ubuntu',
                  style: TextStyle(color: t.yellow),
                ),
                const TextSpan(text: '@'),
                TextSpan(
                  text: 'dev1',
                  style: TextStyle(color: t.green, fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: ':'),
                TextSpan(
                  text: '~/app',
                  style: TextStyle(color: t.blue, fontWeight: FontWeight.bold),
                ),
                const TextSpan(text: r'$ ls'),
              ],
            ),
          ),
          Text.rich(
            TextSpan(
              style: style,
              children: [
                TextSpan(
                  text: 'src  ',
                  style: TextStyle(color: t.blue, fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text: 'run.sh  ',
                  style: TextStyle(color: t.green),
                ),
                const TextSpan(text: 'README.md'),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(r'$ ', style: style),
              cursorBox,
            ],
          ),
        ],
      ),
    );
  }
}
