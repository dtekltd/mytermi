/// Mirrors the shell's current input line on the client side, by watching
/// every byte we send. Used to drive command suggestions.
///
/// We only *know* the line while the user types plainly at the end of it.
/// Anything that lets the shell change the line behind our back (arrows,
/// Tab completion, Ctrl-R, Ctrl-A...) makes the line [reliable] == false
/// until the next Enter / Ctrl-C / Ctrl-U.
class InputLineTracker {
  final List<int> _runes = [];
  bool _reliable = true;
  bool _cursorAtEnd = true; // true whenever _reliable is true

  static const _pasteStart = '\x1b[200~';
  static const _pasteEnd = '\x1b[201~';

  String get line => String.fromCharCodes(_runes);
  bool get reliable => _reliable;

  void reset() {
    _runes.clear();
    _reliable = true;
    _cursorAtEnd = true;
  }

  void invalidate() {
    _runes.clear();
    _reliable = false;
    _cursorAtEnd = false;
  }

  /// Feeds bytes about to be sent to the shell. Returns the lines that were
  /// submitted with Enter while we knew their exact content.
  List<String> feed(String data) {
    // Bracketed paste: the shell inserts the text literally, newlines included.
    if (data.startsWith(_pasteStart) && data.endsWith(_pasteEnd)) {
      final body = data.substring(_pasteStart.length, data.length - _pasteEnd.length);
      if (!_reliable || body.runes.any((r) => r < 0x20 || r == 0x7f)) {
        invalidate();
      } else {
        _runes.addAll(body.runes);
      }
      return const [];
    }

    final commits = <String>[];
    for (final r in data.runes) {
      switch (r) {
        case 0x0d || 0x0a: // Enter
          final l = line;
          if (_reliable && l.trim().isNotEmpty) commits.add(l);
          reset();
        case 0x7f || 0x08: // Backspace
          if (_runes.isNotEmpty) _runes.removeLast();
        case 0x03: // Ctrl-C discards the line
          reset();
        case 0x05: // Ctrl-E: cursor to end of line
          _cursorAtEnd = true;
        case 0x15: // Ctrl-U: kill to start of line
          if (_cursorAtEnd) {
            reset();
          } else {
            invalidate();
          }
        case 0x17: // Ctrl-W: delete previous word
          if (_reliable) {
            while (_runes.isNotEmpty && _runes.last == 0x20) {
              _runes.removeLast();
            }
            while (_runes.isNotEmpty && _runes.last != 0x20) {
              _runes.removeLast();
            }
          } else {
            invalidate();
          }
        default:
          if (r < 0x20) {
            invalidate(); // ESC (arrows, Alt), Tab, Ctrl-A/R/L...
          } else if (_reliable) {
            _runes.add(r);
          }
      }
    }
    return commits;
  }

  /// Bytes that turn the current line into [target], with as little
  /// redrawing as possible.
  String replaceWith(String target) {
    final l = line;
    if (_reliable && target.startsWith(l)) return target.substring(l.length);
    return '\x05\x15$target'; // Ctrl-E, Ctrl-U, then type it
  }
}
