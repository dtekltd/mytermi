import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/services/session_manager.dart';
import 'package:xterm/xterm.dart';

void main() {
  List<String> replies(String input) {
    final out = <String>[];
    Terminal(onOutput: out.add).write(input);
    return out;
  }

  test('Device Attributes queries are still answered', () {
    expect(replies('\x1b[c'), ['\x1b[?1;2c']);
    expect(replies('\x1b[0c'), ['\x1b[?1;2c']);
    expect(replies('\x1b[>c'), isNotEmpty);
  });

  test('Linux console cursor shape (CSI ? Ps c) is not mistaken for a query', () {
    // nano under TERM=linux (e.g. in an LXC via `pct enter`) sends these on every
    // redraw; answering them fed "ESC [ ? 1 ; 2 c" into nano: "Unknown sequence".
    expect(replies('\x1b[?25l\x1b[?1c'), isEmpty);
    expect(replies('\x1b[?25h\x1b[?0c'), isEmpty);
    expect(replies('\x1b[?6;0;0c'), isEmpty);
  });

  test('a reconnect resets what the previous program left set', () {
    final t = Terminal()
      ..write('scrollback\r\n')
      ..write('\x1b[?1049h\x1b[?1h\x1b=\x1b[?2004h\x1b[?25l\x1b[?1000h');
    expect(t.isUsingAltBuffer, isTrue);
    t.write(SshSession.resetModes);
    expect(t.isUsingAltBuffer, isFalse);
    expect(t.appKeypadMode, isFalse);
    expect(t.bracketedPasteMode, isFalse);
    expect(t.cursorVisibleMode, isTrue);
    expect(t.mouseMode, MouseMode.none);
    expect(t.buffer.lines[0].toString().trim(), 'scrollback'); // history kept
  });

  test('after `clear` (CSI 3 J drops the scrollback) selections land on the right row', () {
    final t = Terminal(maxLines: 10000);
    for (var i = 0; i < 100; i++) {
      t.write('line $i\r\n');
    }
    t.write('\x1b[H\x1b[2J\x1b[3J'); // what `clear` prints
    t.write('first\r\nsecond\r\n');
    expect(t.buffer.lines.length, t.viewHeight);
    final row = t.buffer.createAnchor(0, 1);
    expect(row.y, 1);
    final c = TerminalController()..setSelection(t.buffer.createAnchor(0, 1), t.buffer.createAnchor(6, 1));
    expect(t.buffer.getText(c.selection!), 'second');
  });
}
