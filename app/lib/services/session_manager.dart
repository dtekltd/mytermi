import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../models/host.dart';
import '../util/ids.dart';
import '../util/snippet_keys.dart';
import 'command_store.dart';
import 'echo_check.dart';
import 'host_store.dart';
import 'input_tracker.dart';
import 'settings_store.dart';

enum SessionStatus { idle, connecting, connected, disconnected }

/// Asks the user to trust a host key. [known] is the previously trusted
/// fingerprint when it changed, null for a first connection.
typedef HostKeyPrompt = Future<bool> Function(String type, String fingerprint, String? known);
typedef PasswordPrompt = Future<String?> Function();

/// One SSH shell + its terminal. Lives independently of any screen, so you
/// can go back to the host list and return to a running session.
class SshSession extends ChangeNotifier {
  SshSession({required this.host, required this.hosts, required this.commands, required this.settings})
      : id = newId() {
    terminal.onOutput = _onTerminalOutput;
    terminal.onResize = _onResize;
    terminal.addListener(_onTerminalChanged);
  }

  final String id;
  final Host host;
  final HostStore hosts;
  final CommandStore commands;
  final SettingsStore settings;

  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  final tracker = InputLineTracker();
  final ctrl = ValueNotifier(false);
  final alt = ValueNotifier(false);
  final suggestions = ValueNotifier<List<Suggestion>>(const []);

  SessionStatus status = SessionStatus.idle;
  bool altBuffer = false; // vim, htop, less, tmux → no suggestions

  /// Set by the terminal screen while it is showing this session.
  HostKeyPrompt? onHostKey;
  PasswordPrompt? onPassword;

  SSHClient? _client;
  SSHSession? _shell;
  String? _sessionPassword; // typed at connect time, reused for reconnects
  int _gen = 0; // bumps on every connect so stale callbacks are ignored
  bool _disposed = false;

  bool get isConnected => status == SessionStatus.connected;

  // ---------------------------------------------------------------- input

  void _onTerminalOutput(String data) {
    var out = data;
    if (ctrl.value && out.length == 1) {
      out = applyCtrl(out);
      ctrl.value = false;
    }
    if (alt.value) {
      out = '\x1b$out';
      alt.value = false;
    }
    send(out);
  }

  static String applyCtrl(String ch) {
    final c = ch.toUpperCase().codeUnitAt(0);
    if (c >= 0x40 && c <= 0x5f) return String.fromCharCode(c & 0x1f); // @ A-Z [ \ ] ^ _
    if (ch == ' ') return '\x00';
    if (ch == '?') return '\x7f';
    return ch;
  }

  /// Every byte to the shell goes through here so the tracker sees it.
  void send(String out) {
    final shell = _shell;
    if (shell == null) return;
    for (final cmd in tracker.feed(out)) {
      _maybeSaveHistory(cmd);
    }
    try {
      shell.write(Uint8List.fromList(utf8.encode(out)));
    } catch (_) {
      _shellEnded(shell, 'Connection lost.'); // channel closed under us
      return;
    }
    refreshSuggestions();
  }

  // Called from TerminalView's layout, so it must never throw: the channel can
  // close (exit, server restart) a moment before we hear about it.
  void _onResize(int w, int h, int pw, int ph) {
    final shell = _shell;
    if (shell == null) return;
    try {
      shell.resizeTerminal(w, h, pw, ph);
    } catch (_) {
      scheduleMicrotask(() => _shellEnded(shell, 'Connection lost.'));
    }
  }

  /// The remote shell [shell] is gone: drop it (and its client) and show [msg].
  void _shellEnded(SSHSession shell, String msg) {
    if (!identical(shell, _shell)) return; // stale: already replaced/closed
    _close();
    _onDisconnected(msg);
  }

  /// Sends a key (arrows, Tab...) honoring sticky Ctrl/Alt.
  void key(TerminalKey k) {
    final c = ctrl.value, a = alt.value;
    ctrl.value = false; // reset first so onOutput doesn't apply them again
    alt.value = false;
    terminal.keyInput(k, ctrl: c, alt: a);
  }

  void applySuggestion(Suggestion s, {bool? run}) {
    if (s.snippet != null && snippetHasKeys(s.text)) return sendKeys(s.text);
    run ??= s.snippet?.autoRun ?? false;
    final text = s.text.replaceAll('\r\n', '\n').replaceAll('\n', '\r');
    send(tracker.replaceWith(text) + (run ? '\r' : ''));
  }

  /// Sends a snippet with key tokens (`{ctrl+b}d`) exactly as written: it is
  /// meant for whatever has the keyboard (tmux, vim...), so the typed line is
  /// left alone and Enter is only pressed where the snippet says `{enter}`.
  void sendKeys(String snippet) {
    ctrl.value = false;
    alt.value = false;
    encodeSnippet(snippet, terminal).forEach(send);
  }

  // ---------------------------------------------------- history / suggest

  void _onTerminalChanged() {
    final a = terminal.isUsingAltBuffer;
    if (a == altBuffer) return;
    altBuffer = a;
    tracker.reset(); // back at a fresh prompt after leaving vim/less
    refreshSuggestions();
  }

  void refreshSuggestions() {
    if (_disposed) return;
    final show = settings.suggestions && isConnected && !altBuffer && tracker.reliable;
    suggestions.value = show ? commands.suggest(host.id, tracker.line) : const [];
  }

  /// Saves [cmd] only if the shell echoed it back, so text typed at hidden
  /// prompts (sudo password, passphrases) never lands in history.
  void _maybeSaveHistory(String cmd) {
    if (!settings.saveHistory || altBuffer || cmd.startsWith(' ')) return; // leading space = "don't record", like bash
    if (echoedAtCursor(terminal, cmd)) {
      commands.addHistory(host.id, cmd);
      return;
    }
    // Echo may still be in flight on a slow link: look at that row again shortly.
    final y = terminal.buffer.absoluteCursorY;
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!_disposed && echoedOnRow(terminal, y, cmd)) commands.addHistory(host.id, cmd);
    });
  }

  Future<int> importHistory() async {
    final client = _client;
    if (client == null) throw 'Not connected';
    final out = await client.run(
      r'cat ~/.bash_history ~/.zsh_history ~/.local/share/fish/fish_history 2>/dev/null',
      stderr: false,
    );
    final n = await commands.importHistory(host.id, utf8.decode(out, allowMalformed: true));
    refreshSuggestions();
    return n;
  }

  // ----------------------------------------------------------- connection

  void _setStatus(SessionStatus s) {
    if (_disposed) return;
    status = s;
    notifyListeners();
    refreshSuggestions();
  }

  void _write(String s) => terminal.write(s);

  Future<void> connect() async {
    _close();
    final gen = ++_gen;
    _setStatus(SessionStatus.connecting);
    _write('\r\n\x1b[90mConnecting to ${host.address} ...\x1b[0m\r\n');

    try {
      final secrets = await hosts.secretsFor(host);

      String? password;
      List<SSHKeyPair>? identities;
      if (host.auth == AuthMethod.password) {
        password = (secrets.password?.isNotEmpty ?? false) ? secrets.password : _sessionPassword;
        password ??= await onPassword?.call();
        if (password == null) {
          _write('\x1b[33mCancelled.\x1b[0m\r\n');
          _setStatus(SessionStatus.disconnected);
          return;
        }
      } else {
        final key = hosts.keyById(host.keyId);
        final ks = key == null ? null : await hosts.keySecrets(key.id);
        if (ks == null) throw 'No private key selected for this host (or the key was deleted). Edit the host to choose a key.';
        identities = SSHKeyPair.fromPem(ks.pem, ks.passphrase);
      }

      final socket = await SSHSocket.connect(host.hostname, host.port, timeout: const Duration(seconds: 10));
      final pw = password;
      final client = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        onPasswordRequest: pw == null ? null : () => pw,
        // Some servers only allow keyboard-interactive; answer prompts with the password.
        onUserInfoRequest: pw == null ? null : (req) => req.prompts.map((_) => pw).toList(),
        onVerifyHostKey: _verifyHostKey,
        keepAliveInterval: const Duration(seconds: 15),
      );
      _client = client;

      await client.authenticated;
      if (gen != _gen || _disposed) {
        client.close();
        return;
      }
      if (host.auth == AuthMethod.password) _sessionPassword = pw;

      final shell = await client.shell(
        pty: SSHPtyConfig(type: 'xterm-256color', width: terminal.viewWidth, height: terminal.viewHeight),
      );
      _shell = shell;

      for (final stream in [shell.stdout, shell.stderr]) {
        stream.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
      }
      shell.done.whenComplete(() {
        if (gen == _gen) _shellEnded(shell, 'Session ended.');
      });
      client.done.catchError((_) {}).whenComplete(() {
        if (gen == _gen) _shellEnded(shell, 'Connection lost.');
      });

      tracker.reset();
      _setStatus(SessionStatus.connected);
    } on SSHAuthFailError {
      _sessionPassword = null;
      _fail('Authentication failed: wrong username, password or key.');
    } on SSHAuthAbortError {
      _fail('Connection closed during authentication.');
    } on SSHHostkeyError {
      _fail('Server host key rejected.');
    } on SocketException catch (e) {
      _fail('Could not connect: ${e.message}');
    } on TimeoutException {
      _fail('Connection timed out.');
    } catch (e) {
      _fail('Error: $e');
    }
  }

  Future<bool> _verifyHostKey(String type, Uint8List fingerprint) async {
    // dartssh2 4.x hands us the OpenSSH-style ASCII string, e.g. "SHA256:ctsa...".
    final fp = utf8.decode(fingerprint, allowMalformed: true);
    final known = hosts.knownFingerprint(host.hostname, host.port);
    if (known == fp) return true;
    final ok = await onHostKey?.call(type, fp, known) ?? false;
    if (ok) await hosts.trustFingerprint(host.hostname, host.port, fp);
    return ok;
  }

  void _fail(String msg) {
    _close();
    _write('\x1b[31m$msg\x1b[0m\r\n');
    _setStatus(SessionStatus.disconnected);
  }

  void _onDisconnected(String msg) {
    if (_disposed || status == SessionStatus.disconnected) return;
    _write('\r\n\x1b[33m$msg\x1b[0m\r\n');
    _setStatus(SessionStatus.disconnected);
  }

  void disconnect() {
    _gen++;
    _close();
    _onDisconnected('Disconnected.');
  }

  void _close() {
    _shell?.close();
    _client?.close();
    _shell = null;
    _client = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _close();
    terminal.removeListener(_onTerminalChanged);
    suggestions.dispose();
    ctrl.dispose();
    alt.dispose();
    controller.dispose();
    super.dispose();
  }
}

/// All open sessions, and which one the terminal screen shows.
class SessionManager extends ChangeNotifier {
  SessionManager({required this.hosts, required this.commands, required this.settings}) {
    settings.addListener(_onSettings);
  }
  final HostStore hosts;
  final CommandStore commands;
  final SettingsStore settings;

  void _onSettings() {
    for (final s in _sessions) {
      s.refreshSuggestions();
    }
  }

  final List<SshSession> _sessions = [];
  SshSession? _active;

  List<SshSession> get sessions => List.unmodifiable(_sessions);
  SshSession? get active => _active;

  Iterable<SshSession> forHost(String hostId) => _sessions.where((s) => s.host.id == hostId);

  /// Display title; numbered when the same host has several sessions.
  String titleOf(SshSession s) {
    final same = forHost(s.host.id).toList();
    return same.length < 2 ? s.host.displayName : '${s.host.displayName} (${same.indexOf(s) + 1})';
  }

  /// Creates a session (not yet connected: the terminal screen starts it so
  /// it can show host-key / password prompts).
  SshSession open(Host host) {
    final s = SshSession(host: host, hosts: hosts, commands: commands, settings: settings);
    s.addListener(notifyListeners);
    _sessions.add(s);
    _active = s;
    notifyListeners();
    return s;
  }

  void activate(SshSession s) {
    if (_active == s) return;
    _active = s;
    notifyListeners();
  }

  void close(SshSession s) {
    final i = _sessions.indexOf(s);
    if (i < 0) return;
    _sessions.removeAt(i);
    if (_active == s) {
      _active = _sessions.isEmpty ? null : _sessions[i.clamp(0, _sessions.length - 1)];
    }
    s.removeListener(notifyListeners);
    s.dispose();
    notifyListeners();
  }

  void closeHost(String hostId) {
    for (final s in forHost(hostId).toList()) {
      close(s);
    }
  }
}
