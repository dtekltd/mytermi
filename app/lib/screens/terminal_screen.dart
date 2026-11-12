import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models/host.dart';
import '../services/command_store.dart';
import '../services/host_store.dart';
import '../services/session_manager.dart';
import '../services/settings_store.dart';
import '../theme.dart';
import '../util/platform.dart';
import '../widgets/common.dart';
import '../widgets/extra_keys.dart';
import '../widgets/suggestion_bar.dart';
import '../widgets/terminal_gestures.dart';
import 'snippets_screen.dart';

/// Shows the manager's active session full screen, with a session switcher,
/// command/suggestion bar and extra keys at the bottom.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.manager, required this.hosts, required this.commands});
  final SessionManager manager;
  final HostStore hosts;
  final CommandStore commands;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {

  final _focusNode = FocusNode();
  final _viewKeys = <String, GlobalKey<TerminalViewState>>{};
  final _scrollControllers = <String, ScrollController>{};
  double _pinchBaseFont = 14;
  double _altScrollAcc = 0;
  bool _popped = false;

  SessionManager get _m => widget.manager;
  SettingsStore get _settings => _m.settings;

  @override
  void initState() {
    super.initState();
    _m.addListener(_onManagerChanged);
    _settings.addListener(_onSettingsChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _m.removeListener(_onManagerChanged);
    _settings.removeListener(_onSettingsChanged);
    for (final s in _m.sessions) {
      s.onHostKey = null;
      s.onPassword = null;
    }
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
    _onFocusChanged(); // IME typing may have just been switched on
  }

  /// Desktop typing goes either straight from key events (default) or, with
  /// IME typing on, through xterm's text-input connection, which is what the
  /// Windows Vietnamese/CJK input methods compose into.
  bool get _useIme => isDesktop && _settings.desktopIme;

  /// xterm opens its text-input connection only when focus arrives with a tap.
  /// Autofocus and focus coming back after a dialog don't, so open it whenever
  /// the terminal gains focus.
  void _onFocusChanged() {
    if (!_useIme || !_focusNode.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.hasFocus) _view?.requestKeyboard();
    });
  }

  /// Terminal colours: follow the app theme unless forced in Settings.
  TerminalTheme _terminalTheme(BuildContext context) => switch (_settings.terminalColors) {
        TerminalColors.dark => terminalThemeDark,
        TerminalColors.light => terminalThemeLight,
        TerminalColors.auto => context.colors.isDark ? terminalThemeDark : terminalThemeLight,
      };

  void _onManagerChanged() {
    if (!mounted) return;
    if (_m.active == null) {
      if (!_popped) {
        _popped = true;
        Navigator.of(context).pop();
      }
      return;
    }
    // Drop per-session UI state of closed sessions.
    final ids = _m.sessions.map((s) => s.id).toSet();
    _viewKeys.removeWhere((id, _) => !ids.contains(id));
    _scrollControllers.removeWhere((id, c) {
      if (ids.contains(id)) return false;
      c.dispose();
      return true;
    });
    setState(() {});
  }

  void _start(SshSession s) {
    s.onHostKey = _askHostKey;
    s.onPassword = () => _askPassword(s.host);
    if (s.status == SessionStatus.idle) s.connect();
  }

  TerminalViewState? get _view => _viewKeys[_m.active?.id]?.currentState;

  // ------------------------------------------------------------ gestures

  void _onArrow(SshSession s, ArrowDir d) => s.key(switch (d) {
        ArrowDir.up => TerminalKey.arrowUp,
        ArrowDir.down => TerminalKey.arrowDown,
        ArrowDir.left => TerminalKey.arrowLeft,
        ArrowDir.right => TerminalKey.arrowRight,
      });

  void _onScroll(SshSession s, double dy) {
    if (s.altBuffer) {
      // Full-screen apps (less, tmux, vim): scroll = arrow keys.
      _altScrollAcc += dy;
      while (_altScrollAcc.abs() >= 20) {
        s.key(_altScrollAcc > 0 ? TerminalKey.arrowUp : TerminalKey.arrowDown);
        _altScrollAcc -= 20 * _altScrollAcc.sign;
      }
      return;
    }
    final c = _scrollControllers[s.id];
    if (c == null || !c.hasClients) return;
    final p = c.position;
    c.jumpTo((p.pixels - dy).clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  void _toggleKeyboard(bool visible) {
    final v = _view;
    if (v == null) return;
    if (visible) {
      v.closeKeyboard();
      _focusNode.unfocus();
    } else {
      v.requestKeyboard();
    }
  }

  // ------------------------------------------------------------- actions

  /// Copy/paste keys. xterm's defaults on Windows/Linux/Android take Ctrl+V and
  /// Ctrl+A, which shells need (literal-next, start of line), so use the
  /// terminal-style Ctrl+Shift+C / Ctrl+Shift+V instead. Apple keeps ⌘C / ⌘V.
  static final Map<ShortcutActivator, Intent>? _shortcuts =
      defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS
          ? null
          : {
              const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true): CopySelectionTextIntent.copy,
              const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
                  const PasteTextIntent(SelectionChangedCause.keyboard),
              const SingleActivator(LogicalKeyboardKey.insert, shift: true):
                  const PasteTextIntent(SelectionChangedCause.keyboard),
            };

  /// Ctrl (⌘ on macOS) with = / - / 0 zooms the terminal font.
  /// Desktop: Enter while text is selected copies it (like Windows Terminal)
  /// instead of sending Enter to the shell.
  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final s = _m.active;
    if (isDesktop &&
        s != null &&
        s.controller.selection != null &&
        (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !kb.isControlPressed &&
        !kb.isAltPressed &&
        !kb.isMetaPressed &&
        !kb.isShiftPressed) {
      if (e is KeyDownEvent) _copy(s);
      return KeyEventResult.handled;
    }
    final mod = defaultTargetPlatform == TargetPlatform.macOS ? kb.isMetaPressed : kb.isControlPressed;
    if (!mod || kb.isAltPressed) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.numpadAdd) {
      _settings.fontSize = _settings.fontSize + 1;
    } else if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      _settings.fontSize = _settings.fontSize - 1;
    } else if (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.numpad0) {
      _settings.fontSize = 14;
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _paste(SshSession s) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.isNotEmpty) s.terminal.paste(text);
  }

  void _copy(SshSession s) {
    final sel = s.controller.selection;
    if (sel == null) return;
    Clipboard.setData(ClipboardData(text: s.terminal.buffer.getText(sel)));
    s.controller.clearSelection();
    _snack('Copied');
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));

  Future<void> _newSession() async {
    final host = await showModalBottomSheet<Host>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('New session', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            for (final h in widget.hosts.hosts)
              ItemCard(
                icon: Icons.terminal_rounded,
                title: h.displayName,
                subtitle: h.address,
                onTap: () => Navigator.pop(ctx, h),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (host == null || !mounted) return;
    _start(_m.open(host));
  }

  Future<void> _closeSession(SshSession s) async {
    if (s.isConnected && _settings.confirmClose) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Close session?'),
          content: Text('Disconnect from ${s.host.address}.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Close')),
          ],
        ),
      );
      if (ok != true) return;
    }
    _m.close(s);
  }

  Future<void> _showMenu(SshSession s) async {
    final c = context.colors;
    final hasSel = s.controller.selection != null;
    final items = <(IconData, String, VoidCallback)>[
      (Icons.bolt, 'Snippets', () => _showSnippets(s)),
      (Icons.content_paste, 'Paste', () => _paste(s)),
      if (hasSel) (Icons.copy, 'Copy', () => _copy(s)),
      (Icons.text_increase, 'Larger text', () => _settings.fontSize += 1),
      (Icons.text_decrease, 'Smaller text', () => _settings.fontSize -= 1),
      if (s.isConnected) (Icons.download, 'Import history', () => _importHistory(s)),
      (Icons.history_toggle_off, 'Clear history', () => _clearHistory(s)),
      if (s.isConnected)
        (Icons.link_off, 'Disconnect', s.disconnect)
      else
        (Icons.refresh, 'Reconnect', s.connect),
      (Icons.close, 'Close session', () => _closeSession(s)),
    ];
    final picked = await showModalBottomSheet<VoidCallback>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (final (icon, label, action) in items)
                Material(
                  color: c.surfaceHi,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.pop(ctx, action),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(icon, color: c.green),
                      const SizedBox(height: 6),
                      Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    picked?.call();
  }

  Future<void> _importHistory(SshSession s) async {
    try {
      final n = await s.importHistory();
      _snack(n == 0 ? 'No shell history found on the server' : 'Imported $n commands from the server');
    } catch (e) {
      _snack('Import failed: $e');
    }
  }

  Future<void> _clearHistory(SshSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear command history?'),
        content: Text('Delete ${widget.commands.historyCount(s.host.id)} saved commands for ${s.host.displayName}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      await widget.commands.clearHistory(s.host.id);
      s.refreshSuggestions();
    }
  }

  Future<void> _onSuggestionLongPress(SshSession s, Suggestion sg) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(sg.text,
                  maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: monoFont)),
            ),
            ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Run now'),
                onTap: () => Navigator.pop(ctx, 'run')),
            ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('Insert into command line (don\'t run)'),
                onTap: () => Navigator.pop(ctx, 'insert')),
            if (sg.isSnippet)
              ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Edit snippet'),
                  onTap: () => Navigator.pop(ctx, 'edit'))
            else ...[
              ListTile(
                  leading: const Icon(Icons.bolt),
                  title: const Text('Save as snippet'),
                  onTap: () => Navigator.pop(ctx, 'save')),
              ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Remove from history'),
                  onTap: () => Navigator.pop(ctx, 'delete')),
            ],
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'run':
        s.applySuggestion(sg, run: true);
      case 'insert':
        s.applySuggestion(sg, run: false);
      case 'edit':
        await editSnippet(context, widget.commands, snippet: sg.snippet);
      case 'save':
        await editSnippet(context, widget.commands, initialCommand: sg.text);
      case 'delete':
        await widget.commands.removeHistory(s.host.id, sg.text);
    }
    s.refreshSuggestions();
  }

  Future<void> _showSnippets(SshSession s) async {
    final c = context.colors;
    final picked = await showModalBottomSheet<Suggestion>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          child: ListenableBuilder(
            listenable: widget.commands,
            builder: (ctx, _) {
              final list = widget.commands.snippets;
              return Column(mainAxisSize: MainAxisSize.min, children: [
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No snippets yet.', style: TextStyle(color: c.textDim)),
                  ),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final sn in list)
                      ItemCard(
                        icon: sn.autoRun ? Icons.bolt : Icons.short_text,
                        iconColor: c.snippet,
                        title: sn.displayName,
                        subtitle: sn.command,
                        onTap: () => Navigator.pop(ctx, Suggestion.snippet(sn)),
                      ),
                  ]),
                ),
                ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('Manage snippets'),
                  onTap: () => Navigator.of(ctx).push(MaterialPageRoute(
                    builder: (_) => SnippetsScreen(store: widget.commands, standalone: true),
                  )),
                ),
              ]);
            },
          ),
        ),
      ),
    );
    if (picked != null && mounted) s.applySuggestion(picked);
    s.refreshSuggestions();
  }

  // ------------------------------------------------------------- prompts

  Future<bool> _askHostKey(String type, String fp, String? known) async {
    final c = context.colors;
    if (!mounted) return false;
    final changed = known != null;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(changed ? Icons.warning_amber : Icons.verified_user,
            color: changed ? c.red : c.green),
        title: Text(changed ? 'HOST KEY HAS CHANGED!' : 'New server'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(changed
                  ? 'The fingerprint differs from last time. The server may have been reinstalled, '
                      'or someone may be intercepting the connection (MITM). Only continue if you are sure.'
                  : 'First connection to this server. Verify the fingerprint before trusting it:'),
              const SizedBox(height: 12),
              Text(type, style: TextStyle(color: c.textDim, fontSize: 12)),
              SelectableText(fp, style: const TextStyle(fontFamily: monoFont, fontSize: 12)),
              const SizedBox(height: 12),
              Text(
                'Compare with the output on the server:\nssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub',
                style: TextStyle(color: c.textDim, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Reject')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: changed ? FilledButton.styleFrom(backgroundColor: c.red) : null,
            child: Text(changed ? 'Trust anyway' : 'Trust'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<String?> _askPassword(Host host) async {
    if (!mounted) return null;
    return showTextInputDialog(
      context,
      title: 'Password cho ${host.address}',
      confirmText: 'Connect',
      obscure: true,
    );
  }

  // ----------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = _m.active;
    if (s == null) return const Scaffold();
    if (s.status == SessionStatus.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start(s));
    } else {
      s.onHostKey ??= _askHostKey;
      s.onPassword ??= () => _askPassword(s.host);
    }
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final viewKey = _viewKeys.putIfAbsent(s.id, GlobalKey<TerminalViewState>.new);
    final scroll = _scrollControllers.putIfAbsent(s.id, ScrollController.new);

    final termTheme = _terminalTheme(context);
    final darkTerm = termTheme.background.computeLuminance() < 0.5;
    final view = TerminalView(
      s.terminal,
      key: viewKey,
      controller: s.controller,
      scrollController: scroll,
      focusNode: _focusNode,
      autofocus: true,
      backgroundOpacity: 1,
      theme: termTheme,
      textStyle: TerminalStyle(fontFamily: monoFont, fontSize: _settings.fontSize),
      cursorType: _settings.cursorType,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      keyboardAppearance: Brightness.dark,
      deleteDetection: true,
      // Desktop: take typed characters straight from key events, unless IME
      // typing is on (Settings > Terminal) for Vietnamese/CJK input methods.
      hardwareKeyboardOnly: isDesktop && !_useIme,
      shortcuts: _shortcuts,
      onKeyEvent: _onKeyEvent,
      // Right click: copy the selection, or paste when nothing is selected.
      onSecondaryTapDown: isDesktop ? (_, _) => s.controller.selection != null ? _copy(s) : _paste(s) : null,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkTerm ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: c.bg,
        resizeToAvoidBottomInset: true,
        body: Column(children: [
          Expanded(
            child: ColoredBox(color: termTheme.background, child: SafeArea(
              bottom: false,
              child: ListenableBuilder(
                listenable: s,
                builder: (context, _) => Stack(fit: StackFit.expand, children: [
                  Positioned.fill(
                    child: isDesktop
                        // Mouse: native click-drag selection and wheel scrolling.
                        ? view
                        : TerminalGestures(
                            onTap: () {
                              s.controller.clearSelection();
                              viewKey.currentState?.requestKeyboard();
                            },
                            onDoubleTap: () {
                              if (_settings.doubleTapTab) s.key(TerminalKey.tab);
                            },
                            step: _settings.swipe.step,
                            onArrow: (d) => _onArrow(s, d),
                            onSelectStart: (p) => viewKey.currentState?.renderTerminal.selectWord(p),
                            onSelectUpdate: (a, b) => viewKey.currentState?.renderTerminal.selectWord(a, b),
                            onScroll: (dy) => _onScroll(s, dy),
                            onPinchStart: () => _pinchBaseFont = _settings.fontSize,
                            onPinch: (scale) => _settings.fontSize = _pinchBaseFont * scale,
                            child: IgnorePointer(child: view),
                          ),
                  ),
                  _SelectionToolbar(session: s, onCopy: () => _copy(s)),
                  if (s.status == SessionStatus.disconnected)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 16,
                      child: Center(
                        child: FilledButton.icon(
                          onPressed: s.connect,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reconnect'),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          )),
          SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _SessionBar(
                manager: _m,
                onBack: () => Navigator.of(context).pop(),
                onNew: _newSession,
                onClose: _closeSession,
                onMenu: () => _showMenu(s),
              ),
              ValueListenableBuilder<List<Suggestion>>(
                valueListenable: s.suggestions,
                builder: (_, list, _) => SuggestionBar(
                  suggestions: list,
                  typed: s.tracker.line,
                  onTap: (sg) => s.applySuggestion(sg),
                  onLongPress: (sg) => _onSuggestionLongPress(s, sg),
                  onPaste: () => _paste(s),
                ),
              ),
              if (!isDesktop)
                ExtraKeys(
                  session: s,
                  keyboardVisible: keyboardVisible,
                  onToggleKeyboard: () => _toggleKeyboard(keyboardVisible),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Floating Copy / Cancel pill shown while text is selected.
class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({required this.session, required this.onCopy});
  final SshSession session;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: session.controller,
      builder: (context, _) {
        if (session.controller.selection == null) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Material(
              color: c.surfaceHi,
              borderRadius: BorderRadius.circular(14),
              elevation: 6,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton.icon(onPressed: onCopy, icon: const Icon(Icons.copy, size: 18), label: const Text('Copy')),
                TextButton(onPressed: session.controller.clearSelection, child: const Text('Cancel')),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// [<]  [● dev1  ⊗] [● prod ⊗] ...  [+] [⊞]
class _SessionBar extends StatelessWidget {
  const _SessionBar({
    required this.manager,
    required this.onBack,
    required this.onNew,
    required this.onClose,
    required this.onMenu,
  });
  final SessionManager manager;
  final VoidCallback onBack;
  final VoidCallback onNew;
  final ValueChanged<SshSession> onClose;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sessions = manager.sessions;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: SizedBox(
        height: 50,
        child: Row(children: [
          SquareButton(
            size: 50,
            tooltip: 'Back to hosts',
            onPressed: onBack,
            child: Icon(Icons.chevron_left, color: c.green, size: 30),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: sessions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _chip(c, sessions[i], sessions.length == 1 ? box.maxWidth : 170),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SquareButton(
            size: 50,
            tooltip: 'New session',
            onPressed: onNew,
            child: Icon(Icons.add, color: c.green, size: 28),
          ),
          const SizedBox(width: 8),
          SquareButton(
            size: 50,
            tooltip: 'Menu',
            onPressed: onMenu,
            child: Icon(Icons.grid_view_rounded, color: c.green, size: 26),
          ),
        ]),
      ),
    );
  }

  Widget _chip(AppPalette c, SshSession s, double width) {
    final active = s == manager.active;
    final dot = switch (s.status) {
      SessionStatus.connected => c.green,
      SessionStatus.connecting || SessionStatus.idle => c.amber,
      SessionStatus.disconnected => c.red,
    };
    return Material(
      color: active ? c.greenBg : c.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        canRequestFocus: false,
        onTap: () => manager.activate(s),
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.only(left: 14, right: 2),
            child: Row(children: [
              Icon(Icons.terminal_rounded, size: 22, color: dot),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  manager.titleOf(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 17, color: active ? c.green : c.text),
                ),
              ),
              IconButton(
                tooltip: 'Close session',
                onPressed: () => onClose(s),
                icon: Icon(Icons.cancel_outlined, color: active ? c.green : c.textDim),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
