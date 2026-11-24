import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  String copy(Terminal t, int fromY, int toY) {
    final b = t.buffer;
    final c = TerminalController()..setSelection(b.createAnchor(0, fromY), b.createAnchor(t.viewWidth, toY));
    return b.getText(c.selection!);
  }

  test('indentation drawn with cursor moves (nano, vim, less, tmux) is kept', () {
    final t = Terminal()..resize(40, 10);
    // Like ncurses: skip the blanks with "cursor forward" instead of writing spaces.
    t.write('root:\r\n\x1b[2Cchild:\r\n\x1b[4Ckey: value\x1b[3Cx\r\n');
    expect(copy(t, 0, 2), 'root:\n  child:\n    key: value   x');
  });

  test('indentation written as spaces is kept, trailing blanks are dropped', () {
    final t = Terminal()..resize(40, 10);
    t.write('a:\r\n  b: 1   \r\n');
    expect(copy(t, 0, 1), 'a:\n  b: 1');
  });

  test('wide characters are not followed by an extra space', () {
    final t = Terminal()..resize(40, 10);
    t.write('\u4E2D\u6587 ok\r\n');
    expect(copy(t, 0, 0), '\u4E2D\u6587 ok');
  });

  test('a long line wrapped by the terminal is copied as one line, its spaces intact', () {
    final t = Terminal()..resize(10, 10);
    t.write('aaaa bbbb cccc\r\n'); // wraps after "aaaa bbbb "
    expect(copy(t, 0, 1), 'aaaa bbbb cccc');
  });
}
