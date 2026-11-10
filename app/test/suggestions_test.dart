import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/models/snippet.dart';
import 'package:mytermi/services/command_store.dart';
import 'package:mytermi/services/echo_check.dart';
import 'package:mytermi/services/input_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('InputLineTracker', () {
    test('tracks typing, backspace and commits on Enter', () {
      final t = InputLineTracker();
      expect(t.feed('ls -lx'), isEmpty);
      t.feed('\x7f');
      t.feed('a');
      expect(t.line, 'ls -la');
      expect(t.feed('\r'), ['ls -la']);
      expect(t.line, '');
    });

    test('unicode backspace removes whole char', () {
      final t = InputLineTracker()..feed('echo chào');
      t.feed('\x7f');
      expect(t.line, 'echo chà');
    });

    test('arrow keys / tab make line unreliable until Enter', () {
      final t = InputLineTracker()..feed('git st');
      t.feed('\t');
      expect(t.reliable, isFalse);
      expect(t.feed('\r'), isEmpty); // shell completed it, we don't know to what
      expect(t.reliable, isTrue);
      t.feed('\x1b[A'); // up arrow
      expect(t.reliable, isFalse);
      expect(t.feed('\r'), isEmpty);
    });

    test('Ctrl-C and Ctrl-U reset; Ctrl-W deletes a word', () {
      final t = InputLineTracker()..feed('rm -rf foo');
      t.feed('\x17');
      expect(t.line, 'rm -rf ');
      t.feed('\x03');
      expect((t.line, t.reliable), ('', true));
      t.feed('abc\x15');
      expect(t.line, '');
    });

    test('Ctrl-E + Ctrl-U recovers from unreliable state', () {
      final t = InputLineTracker()..feed('x\x1b[D');
      expect(t.reliable, isFalse);
      t.feed('\x15'); // cursor might be mid-line: still unknown
      expect(t.reliable, isFalse);
      t.feed('\x05\x15docker ps');
      expect((t.line, t.reliable), ('docker ps', true));
    });

    test('bracketed paste appends single-line text, invalidates multi-line', () {
      final t = InputLineTracker()..feed('echo ');
      t.feed('\x1b[200~hello\x1b[201~');
      expect(t.line, 'echo hello');
      t.feed('\x1b[200~a\nb\x1b[201~');
      expect(t.reliable, isFalse);
    });

    test('replaceWith sends only the missing suffix when possible', () {
      final t = InputLineTracker()..feed('sudo sys');
      expect(t.replaceWith('sudo systemctl status nginx'), 'temctl status nginx');
      expect(t.replaceWith('htop'), '\x05\x15htop');
      t.feed('\t');
      expect(t.replaceWith('sudo systemctl'), '\x05\x15sudo systemctl');
    });

    test('Enter with whitespace-only line commits nothing', () {
      expect(InputLineTracker().feed('   \r'), isEmpty);
    });
  });

  group('CommandStore', () {
    late CommandStore store;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = await CommandStore.load();
    });

    test('prefix matches first, ranked by frequency', () async {
      await store.addHistory('h', 'git status');
      await store.addHistory('h', 'git push');
      await store.addHistory('h', 'git push');
      await store.addHistory('h', 'cd /var/log/git');
      final s = store.suggest('h', 'git').map((e) => e.text).toList();
      expect(s, ['git push', 'git status', 'cd /var/log/git']);
    });

    test('history is per host and exact input is not suggested', () async {
      await store.addHistory('a', 'ls');
      await store.addHistory('a', 'ls -la');
      expect(store.suggest('b', 'ls'), isEmpty);
      expect(store.suggest('a', 'ls').map((e) => e.text), ['ls -la']);
    });

    test('snippets show on empty input and match by name', () async {
      await store.saveSnippet(Snippet(id: '1', name: 'Restart nginx', command: 'sudo systemctl restart nginx'));
      await store.addHistory('h', 'uptime');
      final empty = store.suggest('h', '');
      expect(empty.first.isSnippet, isTrue);
      expect(empty.last.text, 'uptime');
      expect(store.suggest('h', 'nginx').single.snippet!.name, 'Restart nginx');
    });

    test('persists across reloads and caps size', () async {
      for (var i = 0; i < CommandStore.maxHistory + 20; i++) {
        await store.addHistory('h', 'cmd $i');
      }
      final again = await CommandStore.load();
      expect(again.historyCount('h'), CommandStore.maxHistory);
    });

    test('import ranks below commands typed in app', () async {
      await store.addHistory('h', 'make deploy');
      final n = await store.importHistory('h', 'make build\nmake test\nmake build\n');
      expect(n, 2);
      expect(store.suggest('h', 'make').first.text, 'make deploy');
    });
  });

  test('parseShellHistory handles bash, zsh and fish formats', () {
    expect(parseShellHistory('#1700000000\nls\n: 1700000001:0;git log\n- cmd: htop\n  when: 1700000002\n\n'),
        ['ls', 'git log', 'htop']);
  });

  group('echo check', () {
    Terminal term(String screen) => Terminal()..resize(40, 10)..write(screen);

    test('accepts a command echoed after the prompt', () {
      expect(echoedAtCursor(term('ubuntu@srv:~\$ ls -la'), 'ls -la'), isTrue);
    });

    test('rejects text that was not echoed', () {
      expect(echoedAtCursor(term('ubuntu@srv:~\$ '), 'hunter2'), isFalse);
    });

    test('rejects password prompt even if password matches prompt text', () {
      final t = term('[sudo] password for ubuntu: ');
      expect(echoedAtCursor(t, 'ubuntu'), isFalse);
      expect(echoedOnRow(t, t.buffer.absoluteCursorY, 'ubuntu'), isFalse);
    });

    test('works for commands that wrap across lines', () {
      final cmd = 'echo ${'x' * 60}';
      final t = term('\$ $cmd');
      expect(echoedAtCursor(t, cmd), isTrue);
    });

    test('late echo is found on the original row', () {
      final t = term('\$ ');
      final y = t.buffer.absoluteCursorY;
      t.write('uptime\r\n 10:00 up 3 days\r\n\$ ');
      expect(echoedOnRow(t, y, 'uptime'), isTrue);
    });
  });
}
