import 'package:flutter/gestures.dart';
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
import 'package:xterm/xterm.dart';

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

  testWidgets('desktop: typed characters come from key events, without clicking the terminal first', (t) async {
    debugIsDesktop = true;
    final s = await open(t);
    final out = <String>[];
    s.terminal.onOutput = out.add;
    await t.pump();
    expect(t.testTextInput.hasAnyClients, isFalse); // no IME connection involved
    await t.sendKeyEvent(LogicalKeyboardKey.keyL);
    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await t.pump();
    expect(out.join(), 'ls');

    // Still works after focus comes back from a dialog (password, host key).
    final dialog = showDialog<void>(context: t.element(find.byType(TerminalScreen)), builder: (_) => const AlertDialog());
    await t.pumpAndSettle();
    Navigator.of(t.element(find.byType(AlertDialog))).pop();
    await dialog;
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.pump();
    expect(out.join(), 'lsa');
    await close(t, s);
  });

  testWidgets('desktop IME typing: composed text (e.g. Vietnamese Telex) reaches the shell once committed', (t) async {
    debugIsDesktop = true;
    app.settings.desktopIme = true;
    final s = await open(t);
    final out = <String>[];
    s.terminal.onOutput = out.add;
    await t.pump();
    // The text-input connection opens without clicking the terminal first.
    expect(t.testTextInput.hasAnyClients, isTrue);
    // Windows rejects a text-input client without a view id (no typing at all).
    final setClient = t.testTextInput.log.lastWhere((c) => c.method == 'TextInput.setClient');
    expect(((setClient.arguments as List)[1] as Map)['viewId'], isNotNull);

    // xterm keeps two spaces in the field for delete detection.
    t.testTextInput.updateEditingValue(const TextEditingValue(
      text: '  vie',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 2, end: 5),
    ));
    await t.pump();
    expect(out, isEmpty); // still composing
    t.testTextInput.updateEditingValue(const TextEditingValue(
      text: '  vi\u1EC7t',
      selection: TextSelection.collapsed(offset: 6),
    ));
    await t.pump();
    expect(out.join(), 'vi\u1EC7t');

    // Special keys still come from key events.
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await t.pump();
    expect(out.last, '\x7f');
    await close(t, s);
  });

  testWidgets('desktop: mouse drag selects the text under the pointer, with scrollback', (t) async {
    debugIsDesktop = true;
    t.view.physicalSize = const Size(1100, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = await open(t);
    for (var i = 0; i < 80; i++) {
      s.terminal.write('line $i\r\n');
    }
    s.terminal.write('target here\r\nafter');
    await t.pumpAndSettle();

    final view = t.state<TerminalViewState>(find.byType(TerminalView));
    final cell = view.renderTerminal.cellSize;
    final b = s.terminal.buffer;
    final y = b.absoluteCursorY - 1; // the "target here" row
    // Where that row is on screen: from the cursor, which sits one row below it.
    final cursor = view.globalCursorRect;
    final start = Offset(cursor.left - cell.width * 5 + 1, cursor.center.dy - cell.height); // column 0 (cursor is after "after")
    final g = await t.startGesture(start, kind: PointerDeviceKind.mouse);
    await t.pump(const Duration(milliseconds: 50));
    await g.moveTo(start + Offset(cell.width * 6, 0));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();

    final sel = s.controller.selection;
    expect(sel, isNotNull);
    expect(sel!.begin.y, y);
    expect(b.getText(sel), startsWith('targe'));
    await close(t, s);
  });

  for (final desktop in [true, false]) {
    testWidgets('Enter with a selection copies it (desktop only), desktop=$desktop', (t) async {
      debugIsDesktop = desktop;
      final s = await open(t);
      s.terminal.write('hello world');
      final out = <String>[];
      s.terminal.onOutput = out.add;
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      final b = s.terminal.buffer;
      s.controller.setSelection(b.createAnchor(0, b.absoluteCursorY), b.createAnchor(5, b.absoluteCursorY));
      await t.pump();

      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      if (desktop) {
        expect(copied, 'hello');
        expect(s.controller.selection, isNull);
        expect(out, isEmpty); // Enter didn't reach the shell
        // Without a selection Enter goes to the shell as usual.
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pump();
        expect(out.join(), '\r');
      } else {
        expect(copied, isNull);
      }
      await t.pump(const Duration(seconds: 3)); // let the "copied" snackbar go
      await close(t, s);
    });
  }

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

  testWidgets('right click pastes even while the program has mouse reporting on (Claude Code)', (t) async {
    debugIsDesktop = true;
    final s = await open(t);
    s.terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h');
    final out = <String>[];
    s.terminal.onOutput = out.add;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'pasted'};
      return null;
    });

    await t.tapAt(t.getCenter(find.byType(TerminalView)), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();

    expect(out, ['\x1b[200~pasted\x1b[201~']); // no mouse report sent to the program
    await close(t, s);
  });
}
