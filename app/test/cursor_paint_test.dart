import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
// The painter isn't exported; this checks the vendored fix (third_party/xterm).
// ignore: implementation_imports
import 'package:xterm/src/ui/painter.dart';

/// Records the lines drawn on it.
class _LineCanvas extends Fake implements Canvas {
  final lines = <(Offset, Offset)>[];
  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines.add((p1, p2));
}

void main() {
  testWidgets('underline and bar cursors are drawn on the cursor row, not the first line', (t) async {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final cell = painter.cellSize;
    final at = Offset(cell.width * 4, cell.height * 3); // column 4, row 3

    final underline = _LineCanvas();
    painter.paintCursor(underline, at, cursorType: TerminalCursorType.underline);
    final (u1, u2) = underline.lines.single;
    expect(u1.dy, closeTo(at.dy + cell.height - 1, 0.01));
    expect(u2.dy, u1.dy);
    expect(u1.dx, at.dx);

    final bar = _LineCanvas();
    painter.paintCursor(bar, at, cursorType: TerminalCursorType.verticalBar);
    final (b1, b2) = bar.lines.single;
    expect(b1.dy, at.dy);
    expect(b2.dy, closeTo(at.dy + cell.height, 0.01));
  });
}
