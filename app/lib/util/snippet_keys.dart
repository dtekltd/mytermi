import 'package:xterm/xterm.dart';

/// Key presses inside snippets, written in braces: `{ctrl+b}d` detaches tmux,
/// `{esc}:wq{enter}` saves in vim.
///
///  - `{ctrl+X}` for a letter, or one of `@ [ \ ] ^ _ space`
///  - `{alt+X}` for any single character (sends Esc first, like Meta)
///  - named keys: enter, tab, esc, space, backspace, delete, insert, home, end,
///    pgup, pgdn, up, down, left, right, f1..f12, also with ctrl+/alt+/shift+
///
/// Only these exact tokens are keys; any other braces (`awk '{print $1}'`,
/// `${HOME}`, `${UP}`) stay plain text.
sealed class SnippetPart {
  const SnippetPart();
}

/// Text typed as-is (newlines become Enter).
class SnippetText extends SnippetPart {
  const SnippetText(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is SnippetText && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'SnippetText($text)';
}

/// Bytes for a Ctrl/Alt chord on a character.
class SnippetBytes extends SnippetPart {
  const SnippetBytes(this.bytes);
  final String bytes;

  @override
  bool operator ==(Object other) => other is SnippetBytes && other.bytes == bytes;
  @override
  int get hashCode => bytes.hashCode;
  @override
  String toString() => 'SnippetBytes(${bytes.codeUnits})';
}

/// A named key, sent through the terminal so it honours the cursor-key mode
/// apps like vim and less switch on.
class SnippetKey extends SnippetPart {
  const SnippetKey(this.key, {this.ctrl = false, this.alt = false, this.shift = false});
  final TerminalKey key;
  final bool ctrl, alt, shift;

  @override
  bool operator ==(Object other) =>
      other is SnippetKey && other.key == key && other.ctrl == ctrl && other.alt == alt && other.shift == shift;
  @override
  int get hashCode => Object.hash(key, ctrl, alt, shift);
  @override
  String toString() => 'SnippetKey($key${ctrl ? ' ctrl' : ''}${alt ? ' alt' : ''}${shift ? ' shift' : ''})';
}

const _named = {
  'enter': TerminalKey.enter,
  'return': TerminalKey.enter,
  'tab': TerminalKey.tab,
  'esc': TerminalKey.escape,
  'escape': TerminalKey.escape,
  'backspace': TerminalKey.backspace,
  'bs': TerminalKey.backspace,
  'delete': TerminalKey.delete,
  'del': TerminalKey.delete,
  'insert': TerminalKey.insert,
  'ins': TerminalKey.insert,
  'home': TerminalKey.home,
  'end': TerminalKey.end,
  'pgup': TerminalKey.pageUp,
  'pageup': TerminalKey.pageUp,
  'pgdn': TerminalKey.pageDown,
  'pagedown': TerminalKey.pageDown,
  'up': TerminalKey.arrowUp,
  'down': TerminalKey.arrowDown,
  'left': TerminalKey.arrowLeft,
  'right': TerminalKey.arrowRight,
  'f1': TerminalKey.f1,
  'f2': TerminalKey.f2,
  'f3': TerminalKey.f3,
  'f4': TerminalKey.f4,
  'f5': TerminalKey.f5,
  'f6': TerminalKey.f6,
  'f7': TerminalKey.f7,
  'f8': TerminalKey.f8,
  'f9': TerminalKey.f9,
  'f10': TerminalKey.f10,
  'f11': TerminalKey.f11,
  'f12': TerminalKey.f12,
};

// {mods+key}: modifiers are ctrl/alt/shift (also control, option, meta);
// the key is one character or a name. Matched case-insensitively. Never right
// after `$`, so shell variables like ${HOME} or ${END} stay text.
final _token = RegExp(r'(?<!\$)\{((?:(?:ctrl|control|alt|option|meta|shift)\+)*)([^{}+\s]|\+|space|[a-z][a-z0-9]+)\}',
    caseSensitive: false);

/// Splits [snippet] into text and key presses.
List<SnippetPart> parseSnippet(String snippet) {
  final parts = <SnippetPart>[];
  var text = StringBuffer();
  var last = 0;
  void flush() {
    if (text.isNotEmpty) parts.add(SnippetText(text.toString()));
    text = StringBuffer();
  }

  for (final m in _token.allMatches(snippet)) {
    final part = _keyFor(m.group(1)!.toLowerCase(), m.group(2)!);
    if (part == null) continue; // not a key: leave it in the text
    text.write(snippet.substring(last, m.start));
    flush();
    parts.add(part);
    last = m.end;
  }
  text.write(snippet.substring(last));
  flush();
  return parts;
}

/// Whether [snippet] contains at least one key token.
bool snippetHasKeys(String snippet) => parseSnippet(snippet).any((p) => p is! SnippetText);

SnippetPart? _keyFor(String mods, String key) {
  final ctrl = mods.contains('ctrl') || mods.contains('control');
  final alt = mods.contains('alt') || mods.contains('option') || mods.contains('meta');
  final shift = mods.contains('shift');
  final name = key.toLowerCase();

  if (_named[name] case final k?) return SnippetKey(k, ctrl: ctrl, alt: alt, shift: shift);

  // A single character, or "space".
  String? ch = name == 'space' ? ' ' : (key.runes.length == 1 ? key : null);
  if (ch == null) return null; // unknown name, e.g. {print}
  if (mods.isEmpty) return ch == ' ' ? const SnippetText(' ') : null; // "{x}" is just text
  if (shift) ch = ch.toUpperCase();
  if (ctrl) {
    final c = _ctrlByte(ch);
    if (c == null) return null;
    ch = c;
  }
  return SnippetBytes(alt ? '\x1b$ch' : ch);
}

/// Control character for Ctrl+[ch] (Ctrl+B = 0x02, Ctrl+[ = Esc, Ctrl+Space = NUL).
String? _ctrlByte(String ch) {
  if (ch == ' ' || ch == '@' || ch == '2') return '\x00';
  final u = ch.toUpperCase().codeUnitAt(0);
  if (u >= 0x40 && u <= 0x5f) return String.fromCharCode(u & 0x1f); // @ A-Z [ \ ] ^ _
  if (ch == '?') return '\x7f';
  return null;
}

/// The chunks [snippet] sends to the shell, in order. Named keys are encoded
/// by [terminal], so arrows follow its current cursor-key mode.
List<String> encodeSnippet(String snippet, Terminal terminal) {
  final out = <String>[];
  for (final p in parseSnippet(snippet)) {
    switch (p) {
      case SnippetText(:final text):
        out.add(text.replaceAll('\r\n', '\n').replaceAll('\n', '\r'));
      case SnippetBytes(:final bytes):
        out.add(bytes);
      case SnippetKey(:final key, :final ctrl, :final alt, :final shift):
        final prev = terminal.onOutput;
        terminal.onOutput = out.add;
        try {
          terminal.keyInput(key, ctrl: ctrl, alt: alt, shift: shift);
        } finally {
          terminal.onOutput = prev;
        }
    }
  }
  return out;
}
