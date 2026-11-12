import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/screens/snippets_screen.dart';
import 'package:mytermi/services/app_services.dart';
import 'package:mytermi/theme.dart';
import 'package:mytermi/util/snippet_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

void main() {
  List<String> enc(String s, [Terminal? t]) => encodeSnippet(s, t ?? Terminal());

  test('tmux detach: Ctrl+B then d', () {
    expect(parseSnippet('{ctrl+b}d'), [const SnippetBytes('\x02'), const SnippetText('d')]);
    expect(enc('{ctrl+b}d').join(), '\x02d');
    expect(snippetHasKeys('{ctrl+b}d'), isTrue);
  });

  test('modifiers and names are case-insensitive, with aliases', () {
    expect(enc('{Ctrl+B}{CONTROL+c}').join(), '\x02\x03');
    expect(enc('{alt+f}{meta+b}{option+.}').join(), '\x1bf\x1bb\x1b.');
    expect(enc('{ctrl+[}{ctrl+space}{ctrl+\\}').join(), '\x1b\x00\x1c');
    expect(enc('{ctrl+alt+x}').join(), '\x1b\x18');
    expect(enc('{alt+shift+a}').join(), '\x1bA');
  });

  test('named keys', () {
    expect(enc('{esc}:wq{enter}').join(), '\x1b:wq\r');
    expect(enc('{tab}{backspace}').join(), '\t\x7f');
    expect(enc('{up}').join(), '\x1b[A');
    expect(enc('{F1}'), isNotEmpty);
  });

  test('arrows follow application cursor-key mode (vim, less)', () {
    final t = Terminal()..write('\x1b='); // xterm switches arrows to app mode with DECKPAM
    expect(enc('{up}', t).join(), '\x1bOA');
  });

  test('other braces stay text', () {
    for (final s in [r"awk '{print $1}'", r'echo ${HOME}', r'cd ${END}/x', '{x}', '{1}', '{foo}', '{ctrl+}', 'a{b,c}', 'f() { :; }']) {
      expect(snippetHasKeys(s), isFalse, reason: '$s -> ${parseSnippet(s)}');
      expect(enc(s).join(), s, reason: s);
    }
  });

  test('newlines become Enter', () {
    expect(enc('ls\npwd{enter}').join(), 'ls\rpwd\r');
  });

  test('the terminal keeps its own output handler', () {
    final got = <String>[];
    final t = Terminal(onOutput: got.add);
    enc('{up}', t);
    t.onOutput!('x');
    expect(got, ['x']);
  });

  testWidgets('editor: key buttons insert tokens; the auto-Enter switch hides for key snippets', (t) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final app = await AppServices.load(startSync: false);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(AppPalette.dark),
      home: Builder(builder: (c) => TextButton(onPressed: () => editSnippet(c, app.commands), child: const Text('open'))),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    expect(find.text('Run immediately when selected'), findsOneWidget);
    await t.tap(find.text('Ctrl+B'));
    await t.pump();
    await t.enterText(find.byType(TextFormField).at(1), '{ctrl+b}d');
    await t.pump();
    expect(find.text('Run immediately when selected'), findsNothing);
    await t.enterText(find.byType(TextFormField).first, 'tmux detach');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(app.commands.snippets.last.command, '{ctrl+b}d');
  });
}
