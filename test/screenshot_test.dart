// Renders screenshots of the main screens (not part of the normal suite).
// Run: SCREENSHOTS=1 flutter test test/screenshot_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/models/host.dart';
import 'package:mytermi/models/snippet.dart';
import 'package:mytermi/screens/home_screen.dart';
import 'package:mytermi/screens/terminal_screen.dart';
import 'package:mytermi/services/app_services.dart';
import 'package:mytermi/services/command_store.dart';
import 'package:mytermi/services/host_store.dart';
import 'package:mytermi/services/session_manager.dart';
import 'package:mytermi/services/settings_store.dart';
import 'package:mytermi/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _font(String family, List<String> paths) async {
  final l = FontLoader(family);
  for (final p in paths) {
    l.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
  }
  await l.load();
}

final _enabled = Platform.environment['SCREENSHOTS'] == '1';

void main() {
  final sdk = '${Platform.environment['HOME']}/sdk/flutter/bin/cache/artifacts/material_fonts';
  late AppServices app;

  setUp(() async {
    await _font('Roboto', ['$sdk/Roboto-Regular.ttf', '$sdk/Roboto-Medium.ttf', '$sdk/Roboto-Bold.ttf']);
    await _font('MaterialIcons', ['$sdk/MaterialIcons-Regular.otf']);
    await _font(monoFont, ['assets/fonts/JetBrainsMono-Regular.ttf', 'assets/fonts/JetBrainsMono-Bold.ttf']);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppServices(
      hosts: await HostStore.load(),
      commands: await CommandStore.load(),
      settings: await SettingsStore.load(),
    );
    await app.hosts.save(Host(id: 'h1', label: 'dev1', hostname: '10.0.0.5', username: 'ubuntu'), const HostSecrets());
    await app.hosts.save(
        Host(id: 'h2', label: 'userver', hostname: 'userver.lan', username: 'tphan', auth: AuthMethod.key),
        const HostSecrets(privateKey: 'x'));
    await app.commands.saveSnippet(Snippet(id: 's1', name: 'Restart nginx', command: 'sudo systemctl restart nginx'));
    await app.commands.saveSnippet(Snippet(id: 's2', name: 'Disk', command: 'df -h'));
    for (final c in ['git status', 'git push origin main', 'git log --oneline -20', 'git status', 'ls -la']) {
      await app.commands.addHistory('h1', c);
    }
  });

  Future<void> phone(WidgetTester t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    t.view.padding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
    t.view.viewPadding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
    addTearDown(t.view.reset);
  }

  SshSession fakeSession() {
    final s = app.sessions.open(app.hosts.hosts.first);
    s.status = SessionStatus.connected; // don't actually connect
    return s;
  }

  for (final (mode, pal) in [('dark', AppPalette.dark), ('light', AppPalette.light)]) {
    testWidgets('home $mode', skip: !_enabled, (t) async {
      await phone(t);
      fakeSession();
      await t.pumpWidget(MaterialApp(theme: buildTheme(pal), debugShowCheckedModeBanner: false, home: HomeScreen(app: app)));
      await t.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/${mode}_1_hosts.png'));
      await t.tap(find.text('Snippets').last);
      await t.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/${mode}_4_snippets.png'));
      await t.tap(find.text('Settings').last);
      await t.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/${mode}_5_settings.png'));
    });

    testWidgets('terminal $mode', skip: !_enabled, (t) async {
      await phone(t);
      final s = fakeSession();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(pal),
        debugShowCheckedModeBanner: false,
        home: TerminalScreen(manager: app.sessions, hosts: app.hosts, commands: app.commands),
      ));
      await t.pump();
      s.terminal.write('\x1b[32m-rw-rw-r--\x1b[0m 1 ubuntu ubuntu  1487 Nov  9 14:34 analysis_options.yaml\r\n'
          '\x1b[32mdrwxrwxr-x\x1b[0m 6 ubuntu ubuntu  4096 Nov  9 14:34 \x1b[1;34mandroid\x1b[0m\r\n'
          '\x1b[32mdrwxrwxr-x\x1b[0m 7 ubuntu ubuntu  4096 Nov  9 14:34 \x1b[1;34mios\x1b[0m\r\n'
          '\x1b[32mdrwxrwxr-x\x1b[0m 6 ubuntu ubuntu  4096 Nov  9 14:32 \x1b[1;34mlib\x1b[0m\r\n'
          '\x1b[32m-rw-rw-r--\x1b[0m 1 ubuntu ubuntu  3933 Nov  9 14:34 pubspec.yaml\r\n\r\n'
          '\x1b[33mubuntu\x1b[0m in \x1b[1;32mdev1\x1b[0m in \x1b[1;36m~/working/mytermi\x1b[0m\r\n'
          '\x1b[32m❯\x1b[0m git');
      s.tracker.feed('git');
      s.refreshSuggestions();
      await t.pump();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/${mode}_2_terminal.png'));

      // Finger down + swipe up: arrow pad with "up" highlighted.
      final g = await t.startGesture(const Offset(250, 250));
      await t.pump(const Duration(milliseconds: 200));
      await g.moveBy(const Offset(0, -30));
      await t.pump();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/${mode}_3_arrow_pad.png'));
      await g.up();
      await t.pump();
      app.sessions.close(s);
      await t.pump();
    });
  }
}
