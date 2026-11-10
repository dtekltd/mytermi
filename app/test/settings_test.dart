import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/main.dart';
import 'package:mytermi/services/app_services.dart';
import 'package:mytermi/services/command_store.dart';
import 'package:mytermi/services/host_store.dart';
import 'package:mytermi/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('defaults and persistence', () async {
    final s = await SettingsStore.load();
    expect(s.themeMode, ThemeMode.system);
    expect(s.fontSize, 14);
    expect((s.suggestions, s.saveHistory, s.doubleTapTab, s.haptics), (true, true, true, true));

    s.themeMode = ThemeMode.light;
    s.fontSize = 99; // clamped
    s.cursorType = TerminalCursorType.underline;
    s.swipe = SwipeSensitivity.high;
    s.haptics = false;
    await Future<void>.delayed(Duration.zero);

    final again = await SettingsStore.load();
    expect(again.themeMode, ThemeMode.light);
    expect(again.fontSize, SettingsStore.maxFont);
    expect(again.cursorType, TerminalCursorType.underline);
    expect(again.swipe.step, 18);
    expect(Haptics.enabled, isFalse);
  });

  test('clear all history and known hosts', () async {
    final hosts = await HostStore.load();
    final cmds = await CommandStore.load();
    await cmds.addHistory('a', 'ls');
    await cmds.addHistory('b', 'pwd');
    await hosts.trustFingerprint('h', 22, 'SHA256:x');
    await cmds.clearAllHistory();
    expect((cmds.historyCount('a'), cmds.historyCount('b')), (0, 0));
    expect(await hosts.clearKnownHosts(), 1);
    expect(hosts.knownFingerprint('h', 22), isNull);
  });

  testWidgets('app follows OS brightness by default, and the override', (t) async {
    final app = await AppServices.load(startSync: false);
    Brightness current() => Theme.of(t.element(find.text('Hosts').first)).brightness;

    t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    await t.pumpWidget(MyTermiApp(app: app));
    await t.pumpAndSettle();
    expect(current(), Brightness.light);

    t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await t.pumpAndSettle();
    expect(current(), Brightness.dark);

    app.settings.themeMode = ThemeMode.light;
    await t.pumpAndSettle();
    expect(current(), Brightness.light);
  });
}
