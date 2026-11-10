import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

/// Terminal colours: follow the app theme, or force one.
enum TerminalColors { auto, dark, light }

/// How far a finger must travel to send one arrow key.
enum SwipeSensitivity {
  low(36),
  medium(26),
  high(18);

  const SwipeSensitivity(this.step);
  final double step;
}

/// User preferences, persisted in shared_preferences.
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._p);
  final SharedPreferences _p;

  static Future<SettingsStore> load() async {
    final s = SettingsStore._(await SharedPreferences.getInstance());
    Haptics.enabled = s.haptics;
    return s;
  }

  T _enum<T extends Enum>(String key, List<T> values, T fallback) {
    final name = _p.getString(key);
    return values.firstWhere((v) => v.name == name, orElse: () => fallback);
  }

  Future<void> _set(String key, Object value) async {
    switch (value) {
      case bool v:
        await _p.setBool(key, v);
      case double v:
        await _p.setDouble(key, v);
      case Enum v:
        await _p.setString(key, v.name);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------- appearance

  ThemeMode get themeMode => _enum('s_theme', ThemeMode.values, ThemeMode.system);
  set themeMode(ThemeMode v) => _set('s_theme', v);

  TerminalColors get terminalColors => _enum('s_term_colors', TerminalColors.values, TerminalColors.auto);
  set terminalColors(TerminalColors v) => _set('s_term_colors', v);

  static const minFont = 9.0, maxFont = 24.0;
  double get fontSize => _p.getDouble('s_font') ?? 14;
  set fontSize(double v) => _set('s_font', v.clamp(minFont, maxFont).roundToDouble());

  TerminalCursorType get cursorType => _enum('s_cursor', TerminalCursorType.values, TerminalCursorType.block);
  set cursorType(TerminalCursorType v) => _set('s_cursor', v);

  // ------------------------------------------------------------ gestures

  SwipeSensitivity get swipe => _enum('s_swipe', SwipeSensitivity.values, SwipeSensitivity.medium);
  set swipe(SwipeSensitivity v) => _set('s_swipe', v);

  bool get doubleTapTab => _p.getBool('s_dtap_tab') ?? true;
  set doubleTapTab(bool v) => _set('s_dtap_tab', v);

  bool get haptics => _p.getBool('s_haptics') ?? true;
  set haptics(bool v) {
    Haptics.enabled = v;
    _set('s_haptics', v);
  }

  // ------------------------------------------------------------- history

  bool get suggestions => _p.getBool('s_suggest') ?? true;
  set suggestions(bool v) => _set('s_suggest', v);

  bool get saveHistory => _p.getBool('s_save_hist') ?? true;
  set saveHistory(bool v) => _set('s_save_hist', v);

  // ------------------------------------------------------------ sessions

  bool get confirmClose => _p.getBool('s_confirm_close') ?? true;
  set confirmClose(bool v) => _set('s_confirm_close', v);
}

/// Haptic feedback that respects the user's setting.
abstract final class Haptics {
  static bool enabled = true;
  static void selection() {
    if (enabled) HapticFeedback.selectionClick();
  }

  static void medium() {
    if (enabled) HapticFeedback.mediumImpact();
  }
}
