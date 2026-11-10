import 'package:flutter/material.dart';

import '../services/command_store.dart';
import '../services/settings_store.dart';
import '../theme.dart';

/// Rounded "command bar": suggestion chips from history/snippets, plus Paste.
class SuggestionBar extends StatelessWidget {
  const SuggestionBar({
    super.key,
    required this.suggestions,
    required this.typed,
    required this.onTap,
    required this.onLongPress,
    required this.onPaste,
  });

  final List<Suggestion> suggestions;
  final String typed;
  final ValueChanged<Suggestion> onTap;
  final ValueChanged<Suggestion> onLongPress;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 50,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      padding: const EdgeInsets.only(left: 4, right: 5),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(children: [
        Expanded(
          child: suggestions.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Text(
                    'Gõ lệnh để xem gợi ý…',
                    style: TextStyle(color: c.textDim, fontSize: 16),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  itemCount: suggestions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) => _chip(c, suggestions[i]),
                ),
        ),
        Material(
          color: c.surfaceHi,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            canRequestFocus: false,
            onTap: onPaste,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Text('Paste', style: TextStyle(color: c.text, fontSize: 15)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _chip(AppPalette c, Suggestion s) {
    const mono = TextStyle(fontFamily: monoFont, fontSize: 14);
    final Widget label;
    if (s.isSnippet) {
      label = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.bolt, size: 16, color: c.amber),
        const SizedBox(width: 3),
        Text(s.snippet!.displayName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ]);
    } else if (typed.isNotEmpty && s.text.startsWith(typed)) {
      // Dim what's already typed, highlight the completion.
      label = Text.rich(TextSpan(style: mono, children: [
        TextSpan(text: typed, style: TextStyle(color: c.textDim)),
        TextSpan(text: s.text.substring(typed.length), style: TextStyle(color: c.text)),
      ]));
    } else {
      label = Text(s.text, style: mono);
    }

    return Material(
      color: s.isSnippet ? c.snippetBg : c.surfaceHi,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        canRequestFocus: false, // keep the soft keyboard on the terminal
        onTap: () {
          Haptics.selection();
          onTap(s);
        },
        onLongPress: () {
          Haptics.medium();
          onLongPress(s);
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Align(
              widthFactor: 1,
              child: DefaultTextStyle.merge(maxLines: 1, overflow: TextOverflow.ellipsis, child: label),
            ),
          ),
        ),
      ),
    );
  }
}
