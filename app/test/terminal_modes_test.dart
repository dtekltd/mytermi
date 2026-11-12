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
}
