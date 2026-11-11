import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../services/session_manager.dart';
import '../services/settings_store.dart';
import '../theme.dart';
import 'common.dart';

/// Keys that mobile soft keyboards lack. Ctrl/Alt are sticky: tap once and
/// the next key (from here or the keyboard) gets the modifier.
class ExtraKeys extends StatelessWidget {
  const ExtraKeys({
    super.key,
    required this.session,
    required this.keyboardVisible,
    required this.onToggleKeyboard,
  });

  final SshSession session;
  final bool keyboardVisible;
  final VoidCallback onToggleKeyboard;

  void _key(TerminalKey k) {
    Haptics.selection();
    session.key(k);
  }

  /// Raw control byte, bypassing sticky modifiers.
  void _raw(String s) {
    Haptics.selection();
    session.send(s);
  }

  void _text(String s) {
    Haptics.selection();
    session.terminal.textInput(s); // goes through onOutput → applies sticky Ctrl/Alt
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 48,
      child: Row(children: [
        Expanded(
          child: ShaderMask(
            // Fade the right edge so it's clear the row scrolls.
            shaderCallback: (r) => const LinearGradient(
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0, 0.9, 1],
            ).createShader(r),
            blendMode: BlendMode.dstIn,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                _btn(c, 'esc', () => _key(TerminalKey.escape)),
                _btn(c, 'tab', () => _key(TerminalKey.tab)),
                _toggle(c, 'ctrl', session.ctrl),
                _toggle(c, 'alt', session.alt),
                _btn(c, '^C', () => _raw('\x03')),
                _btn(c, '^D', () => _raw('\x04')),
                _btn(c, '^Z', () => _raw('\x1a')),
                _btn(c, '^L', () => _raw('\x0c')),
                _btn(c, '^R', () => _raw('\x12')),
                _btn(c, '|', () => _text('|')),
                _btn(c, '-', () => _text('-')),
                _btn(c, '/', () => _text('/')),
                _btn(c, '~', () => _text('~')),
                _btn(c, 'home', () => _key(TerminalKey.home)),
                _btn(c, 'end', () => _key(TerminalKey.end)),
                _btn(c, 'pgup', () => _key(TerminalKey.pageUp)),
                _btn(c, 'pgdn', () => _key(TerminalKey.pageDown)),
                _btn(c, '↑', () => _key(TerminalKey.arrowUp)),
                _btn(c, '↓', () => _key(TerminalKey.arrowDown)),
                _btn(c, '←', () => _key(TerminalKey.arrowLeft)),
                _btn(c, '→', () => _key(TerminalKey.arrowRight)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 10, left: 4),
          child: SquareButton(
            tooltip: keyboardVisible ? 'Hide keyboard' : 'Show keyboard',
            onPressed: onToggleKeyboard,
            child: Icon(
              keyboardVisible ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined,
              color: c.green,
            ),
          ),
        ),
      ]),
    );
  }

  TextStyle _style(AppPalette c) => TextStyle(color: c.green, fontSize: 17, fontWeight: FontWeight.w500);

  Widget _btn(AppPalette c, String label, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(10),
        canRequestFocus: false,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(label, style: _style(c)),
        ),
      );

  Widget _toggle(AppPalette c, String label, ValueNotifier<bool> state) => ValueListenableBuilder<bool>(
        valueListenable: state,
        builder: (_, on, _) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          child: Material(
            color: on ? c.green : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              canRequestFocus: false,
              onTap: () {
                Haptics.selection();
                state.value = !state.value;
              },
              child: Container(
                constraints: const BoxConstraints(minWidth: 48),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(label, style: on ? _style(c).copyWith(color: c.bg) : _style(c)),
              ),
            ),
          ),
        ),
      );
}
