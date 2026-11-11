import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/models/host.dart';
import 'package:mytermi/screens/terminal_screen.dart';
import 'package:mytermi/services/app_services.dart';
import 'package:mytermi/services/session_manager.dart';
import 'package:mytermi/theme.dart';
import 'package:mytermi/util/platform.dart';
import 'package:mytermi/widgets/extra_keys.dart';
import 'package:mytermi/widgets/terminal_gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppServices app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = await AppServices.load(startSync: false);
    await app.hosts.save(Host(id: 'h1', label: 'dev1', hostname: '10.0.0.5', username: 'ubuntu'), const HostSecrets());
  });
  tearDown(() => debugIsDesktop = null);

  Future<SshSession> open(WidgetTester t) async {
    final s = app.sessions.open(app.hosts.hosts.first);
    s.status = SessionStatus.connected; // don't actually connect
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(AppPalette.dark),
      home: TerminalScreen(manager: app.sessions, hosts: app.hosts, commands: app.commands),
    ));
    await t.pump();
    return s;
  }

  Future<void> close(WidgetTester t, SshSession s) async {
    app.sessions.close(s);
    await t.pump();
  }

  testWidgets('phone layout: touch gestures and the extra-keys row', (t) async {
    debugIsDesktop = false;
    final s = await open(t);
    expect(find.byType(TerminalGestures), findsOneWidget);
    expect(find.byType(ExtraKeys), findsOneWidget);
    await close(t, s);
  });

  testWidgets('desktop layout: mouse goes to the terminal, no extra-keys row', (t) async {
    debugIsDesktop = true;
    final s = await open(t);
    expect(find.byType(TerminalGestures), findsNothing);
    expect(find.byType(ExtraKeys), findsNothing);
    await close(t, s);
  });

  testWidgets('desktop: typed text reaches the shell without clicking the terminal first', (t) async {
    debugIsDesktop = true;
    final s = await open(t);
    final out = <String>[];
    s.terminal.onOutput = out.add;
    await t.pump();
    // Autofocus alone doesn't open xterm's text-input connection.
    expect(t.testTextInput.hasAnyClients, isTrue);
    t.testTextInput.enterText('  ls'); // xterm keeps two spaces for delete detection
    await t.pump();
    expect(out.join(), 'ls');

    // Focus coming back after a dialog (password, host key) reopens it too.
    final dialog = showDialog<void>(context: t.element(find.byType(TerminalScreen)), builder: (_) => const AlertDialog());
    await t.pumpAndSettle();
    expect(t.testTextInput.hasAnyClients, isFalse);
    Navigator.of(t.element(find.byType(AlertDialog))).pop();
    await dialog;
    await t.pumpAndSettle();
    expect(t.testTextInput.hasAnyClients, isTrue);
    await close(t, s);
  });

  testWidgets('Ctrl+= / Ctrl+- / Ctrl+0 zoom the terminal font', (t) async {
    debugIsDesktop = true;
    final s = await open(t);
    expect(app.settings.fontSize, 14);

    Future<void> ctrl(LogicalKeyboardKey k) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(k);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
    }

    await ctrl(LogicalKeyboardKey.equal);
    await ctrl(LogicalKeyboardKey.equal);
    expect(app.settings.fontSize, 16);
    await ctrl(LogicalKeyboardKey.minus);
    expect(app.settings.fontSize, 15);
    await ctrl(LogicalKeyboardKey.digit0);
    expect(app.settings.fontSize, 14);
    await close(t, s);
  });

  testWidgets('Ctrl+A and Ctrl+V reach the shell; Ctrl+Shift+V pastes', (t) async {
    debugIsDesktop = true;
    final s = await open(t);
    final out = <String>[];
    s.terminal.onOutput = out.add;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'pasted'};
      return null;
    });

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();

    expect(out.join(), contains('\x01')); // Ctrl+A: start of line
    expect(out.join(), contains('\x16')); // Ctrl+V: literal next
    expect(out.join(), contains('pasted'));
    await close(t, s);
  });
}
