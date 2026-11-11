import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';

import '../env.dart';
import '../services/app_services.dart';
import '../services/settings_store.dart';
import '../theme.dart';
import '../util/platform.dart';
import '../widgets/common.dart';
import '../widgets/settings_tiles.dart';
import 'account_screen.dart';
import 'keys_screen.dart';
import 'login_screen.dart';

final sourceUrl = Uri.parse('https://github.com/dtekltd/mytermi');
const donateAmounts = [5, 10, 20];
Uri donateUrl(int usd) => Uri.parse('https://paypal.me/phthosting/${usd}USD');

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
            const SectionLabel('Account & sync'),
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
                  title: 'Sign in / Create account',
                  subtitle: 'Sync hosts, keys and snippets across devices (end-to-end encrypted)',
                  trailing: Icon(Icons.chevron_right, color: context.colors.textDim),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LoginScreen(app: app))),
                ),
            ]),

            // ------------------------------------------------ appearance
            const SectionLabel('Appearance'),
            SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.brightness_6_outlined,
                  title: 'Theme',
                  below: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, label: Text('System')),
                      ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                    ],
                    selected: {s.themeMode},
                    onSelectionChanged: (v) => s.themeMode = v.first,
                  ),
                ),
                SettingsTile(
                  icon: Icons.palette_outlined,
                  title: 'Terminal colors',
                  subtitle: 'Keep the terminal dark while the app is in light mode',
                  below: SegmentedButton<TerminalColors>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: TerminalColors.auto, label: Text('Theo app')),
                      ButtonSegment(value: TerminalColors.light, label: Text('Light')),
                      ButtonSegment(value: TerminalColors.dark, label: Text('Dark')),
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
                  title: 'Font size',
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
                  title: 'Cursor style',
                  below: SegmentedButton<TerminalCursorType>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: TerminalCursorType.block, label: Text('Block')),
                      ButtonSegment(value: TerminalCursorType.underline, label: Text('Underline')),
                      ButtonSegment(value: TerminalCursorType.verticalBar, label: Text('Thanh')),
                    ],
                    selected: {s.cursorType},
                    onSelectionChanged: (v) => s.cursorType = v.first,
                  ),
                ),
              ],
            ),

            // -------------------------------------------------- gestures
            const SectionLabel('Gestures'),
            SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.swipe,
                  title: 'Arrow swipe sensitivity',
                  subtitle: 'High = shorter swipe per key press',
                  below: SegmentedButton<SwipeSensitivity>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: SwipeSensitivity.low, label: Text('Low')),
                      ButtonSegment(value: SwipeSensitivity.medium, label: Text('Medium')),
                      ButtonSegment(value: SwipeSensitivity.high, label: Text('Cao')),
                    ],
                    selected: {s.swipe},
                    onSelectionChanged: (v) => s.swipe = v.first,
                  ),
                ),
                SettingsSwitch(
                  icon: Icons.touch_app_outlined,
                  title: 'Double tap = Tab key',
                  value: s.doubleTapTab,
                  onChanged: (v) => s.doubleTapTab = v,
                ),
                SettingsSwitch(
                  icon: Icons.vibration,
                  title: 'Haptic feedback',
                  value: s.haptics,
                  onChanged: (v) => s.haptics = v,
                ),
                SettingsSwitch(
                  icon: Icons.logout,
                  title: 'Confirm before closing a session',
                  value: s.confirmClose,
                  onChanged: (v) => s.confirmClose = v,
                ),
              ],
            ),

            // --------------------------------------------------- history
            const SectionLabel('Suggestions & history'),
            SettingsGroup(
              children: [
                SettingsSwitch(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Suggest commands while typing',
                  value: s.suggestions,
                  onChanged: (v) => s.suggestions = v,
                ),
                SettingsSwitch(
                  icon: Icons.history,
                  title: 'Save command history',
                  subtitle: 'Only saves commands echoed by the server — never passwords',
                  value: s.saveHistory,
                  onChanged: (v) => s.saveHistory = v,
                ),
              ],
            ),

            // ------------------------------------------------- data
            const SectionLabel('Data & security'),
            SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.key_rounded,
                  title: 'Private keys',
                  subtitle: 'Manage SSH keys shared across hosts',
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
                  title: 'Clear command history',
                  danger: true,
                  onTap: () => _confirm(
                    context,
                    title: 'Clear all command history?',
                    body: 'History for all hosts will be deleted. Snippets are kept.',
                    action: () async {
                      await app.commands.clearAllHistory();
                      for (final x in app.sessions.sessions) {
                        x.refreshSuggestions();
                      }
                      return 'Command history cleared';
                    },
                  ),
                ),
                SettingsTile(
                  icon: Icons.gpp_maybe_outlined,
                  title: 'Forget trusted host keys',
                  subtitle: 'You will be asked to verify the fingerprint on the next connection',
                  danger: true,
                  onTap: () => _confirm(
                    context,
                    title: 'Forget all host keys?',
                    body: 'You will need to verify the fingerprint again when connecting to each server.',
                    action: () async => 'Removed ${await app.hosts.clearKnownHosts()} host keys',
                  ),
                ),
              ],
            ),

            const SectionLabel('About'),
            SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.info_outline,
                  title: 'MyTermi',
                  subtitle: 'SSH client · version 1.0.0${isProd ? '' : ' · $appEnv'}',
                ),
                SettingsTile(
                  icon: Icons.code,
                  title: 'Source code',
                  subtitle: 'github.com/dtekltd/mytermi · Apache License 2.0',
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _open(context, sourceUrl),
                ),
                // Store rules require in-app purchase for tips on iOS/Android, so the
                // PayPal links are only offered in the desktop builds.
                if (isDesktop)
                  SettingsTile(
                    icon: Icons.coffee_outlined,
                    title: 'Buy me a coffee',
                    subtitle: 'MyTermi is free. If it helps you, a tip via PayPal keeps it going.',
                    below: Wrap(
                      spacing: 8,
                      children: [
                        for (final usd in donateAmounts)
                          OutlinedButton(
                            onPressed: () => _open(context, donateUrl(usd)),
                            child: Text('$usd USD'),
                          ),
                      ],
                    ),
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

  Future<void> _open(BuildContext context, Uri url) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
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
