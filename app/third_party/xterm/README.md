# xterm.dart 4.0.0 (vendored)

Copy of [xterm.dart](https://github.com/TerminalStudio/xterm.dart) 4.0.0 (MIT, see LICENSE)
with these fixes on top:

1. `lib/src/ui/custom_text_edit.dart`: the text-input configuration carries the
   Flutter view id. The Windows embedder rejects a text-input client without one
   ("Could not set client, view ID is null."), so typed characters and input
   methods (Vietnamese Telex, CJK) never reached the terminal on Windows.
2. `lib/src/ui/painter.dart`: the underline and vertical-bar cursors are drawn on
   the cursor's row. They ignored the row offset and always showed on the first line.

Only `lib/` is kept. Drop this folder and go back to the pub.dev package once
upstream ships both fixes.
