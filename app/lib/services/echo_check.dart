import 'package:xterm/xterm.dart';

/// Helpers that look at what the terminal actually displays, to decide
/// whether a submitted line was echoed by the shell (i.e. it was a real
/// command, not text typed at a hidden password prompt).

// The last alternative matches localized sudo/passwd prompts on servers set to a
// Vietnamese locale, written as escapes so the source stays ASCII.
final _secretPrompt = RegExp(
  'password|passphrase|passcode|pin:|m\u1EADt kh\u1EA9u',
  caseSensitive: false,
  unicode: true,
);

/// First/last buffer rows of the soft-wrapped line containing row [y].
(int, int) wrappedGroup(Terminal t, int y) {
  final lines = t.buffer.lines;
  var start = y, end = y;
  while (start > 0 && y - start < 50 && lines[start].isWrapped) {
    start--;
  }
  while (end + 1 < lines.length && end - y < 50 && lines[end + 1].isWrapped) {
    end++;
  }
  return (start, end);
}

/// True if the text right before the cursor ends with [cmd] and the prompt
/// in front of it doesn't look like a password prompt. Call before the
/// Enter is sent.
bool echoedAtCursor(Terminal t, String cmd) {
  final buf = t.buffer;
  final y = buf.absoluteCursorY;
  final (start, _) = wrappedGroup(t, y);
  final sb = StringBuffer();
  for (var i = start; i < y; i++) {
    sb.write(buf.lines[i].getText());
  }
  sb.write(buf.lines[y].getText(0, buf.cursorX));
  final text = sb.toString();
  final typed = cmd.trimRight();
  if (typed.isEmpty || !text.endsWith(typed)) return false;
  return !_secretPrompt.hasMatch(text.substring(0, text.length - typed.length));
}

/// Looser check used after a delay (echo arrived late): [cmd] appears on
/// the wrapped line at row [y] and isn't preceded by a password prompt.
bool echoedOnRow(Terminal t, int y, String cmd) {
  final lines = t.buffer.lines;
  if (y < 0 || y >= lines.length) return false;
  final (start, end) = wrappedGroup(t, y);
  final sb = StringBuffer();
  for (var i = start; i <= end; i++) {
    sb.write(lines[i].getText());
  }
  final text = sb.toString();
  final typed = cmd.trimRight();
  final at = text.indexOf(typed);
  return typed.isNotEmpty && at >= 0 && !_secretPrompt.hasMatch(text.substring(0, at));
}
