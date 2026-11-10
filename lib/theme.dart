import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

const monoFont = 'JetBrainsMono';

/// App colours for one brightness. Read with `context.colors`.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceHi,
    required this.border,
    required this.text,
    required this.textDim,
    required this.green,
    required this.greenBg,
    required this.onGreen,
    required this.orange,
    required this.blue,
    required this.red,
    required this.amber,
    required this.snippet,
    required this.snippetBg,
    required this.shadow,
  });

  final Brightness brightness;
  final Color bg, surface, surfaceHi, border, text, textDim;
  final Color green, greenBg, onGreen, orange, blue, red, amber;
  final Color snippet, snippetBg, shadow;

  bool get isDark => brightness == Brightness.dark;

  static const dark = AppPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF1E2133),
    surface: Color(0xFF2B2E44),
    surfaceHi: Color(0xFF383C58),
    border: Color(0xFF3F4363),
    text: Color(0xFFF2F3F8),
    textDim: Color(0xFF8E92AD),
    green: Color(0xFF3FCF8E),
    greenBg: Color(0xFF1E4A3C),
    onGreen: Color(0xFF06261A),
    orange: Color(0xFFE8622F),
    blue: Color(0xFF3B9BFF),
    red: Color(0xFFE5606A),
    amber: Color(0xFFF2B84B),
    snippet: Color(0xFF8A6D1F),
    snippetBg: Color(0xFF4A3F22),
    shadow: Color(0x73000000),
  );

  static const light = AppPalette(
    brightness: Brightness.light,
    bg: Color(0xFFF2F3F8),
    surface: Color(0xFFFFFFFF),
    surfaceHi: Color(0xFFE5E7F0),
    border: Color(0xFFD6D9E4),
    text: Color(0xFF1B1E2E),
    textDim: Color(0xFF6A6F8C),
    green: Color(0xFF16955E),
    greenBg: Color(0xFFD3F1E3),
    onGreen: Color(0xFFFFFFFF),
    orange: Color(0xFFE8622F),
    blue: Color(0xFF2476DB),
    red: Color(0xFFD23C48),
    amber: Color(0xFFC48A12),
    snippet: Color(0xFFC9A030),
    snippetBg: Color(0xFFF6EBCB),
    shadow: Color(0x12000000),
  );

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(AppPalette? other, double t) => t < 0.5 || other == null ? this : other;
}

extension AppPaletteContext on BuildContext {
  AppPalette get colors {
    final theme = Theme.of(this);
    return theme.extension<AppPalette>() ??
        (theme.brightness == Brightness.dark ? AppPalette.dark : AppPalette.light);
  }
}

ThemeData buildTheme(AppPalette c) {
  final scheme = ColorScheme.fromSeed(seedColor: c.green, brightness: c.brightness).copyWith(
    primary: c.green,
    onPrimary: c.onGreen,
    surface: c.bg,
    onSurface: c.text,
    onSurfaceVariant: c.textDim,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface,
    surfaceContainerHighest: c.surfaceHi,
    outline: c.border,
    outlineVariant: c.border,
    error: c.red,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: c.brightness,
    colorScheme: scheme,
    extensions: [c],
    scaffoldBackgroundColor: c.bg,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: c.surface, surfaceTintColor: Colors.transparent),
    dialogTheme: DialogThemeData(backgroundColor: c.surface, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.green, width: 1.5),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.border, space: 1),
    listTileTheme: ListTileThemeData(iconColor: c.textDim),
  );
}

const terminalThemeDark = TerminalTheme(
  cursor: Color(0xFF3FCF8E),
  selection: Color(0x663B9BFF),
  foreground: Color(0xFFE6E8F0),
  background: Color(0xFF1E2133),
  black: Color(0xFF2B2E44),
  red: Color(0xFFF0707A),
  green: Color(0xFF3FCF8E),
  yellow: Color(0xFFF2B84B),
  blue: Color(0xFF4D9DFF),
  magenta: Color(0xFFC792EA),
  cyan: Color(0xFF4FD1D9),
  white: Color(0xFFD7DAE5),
  brightBlack: Color(0xFF6B7094),
  brightRed: Color(0xFFFF8A93),
  brightGreen: Color(0xFF6BE3AA),
  brightYellow: Color(0xFFFFD27A),
  brightBlue: Color(0xFF7DB8FF),
  brightMagenta: Color(0xFFDDB3F5),
  brightCyan: Color(0xFF7FE6EC),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFF2B84B),
  searchHitBackgroundCurrent: Color(0xFF3FCF8E),
  searchHitForeground: Color(0xFF1E2133),
);

/// Light terminal: darker ANSI colours so they stay readable on white.
const terminalThemeLight = TerminalTheme(
  cursor: Color(0xFF16955E),
  selection: Color(0x552476DB),
  foreground: Color(0xFF24283B),
  background: Color(0xFFF2F3F8),
  black: Color(0xFF24283B),
  red: Color(0xFFC8303C),
  green: Color(0xFF14874F),
  yellow: Color(0xFF9A6A00),
  blue: Color(0xFF1F63C6),
  magenta: Color(0xFF8E3FB5),
  cyan: Color(0xFF0E7F87),
  white: Color(0xFF8A8FA6),
  brightBlack: Color(0xFF6A6F8C),
  brightRed: Color(0xFFE0474F),
  brightGreen: Color(0xFF1EA868),
  brightYellow: Color(0xFFB98200),
  brightBlue: Color(0xFF2F7BE6),
  brightMagenta: Color(0xFFA855D0),
  brightCyan: Color(0xFF13A0A9),
  brightWhite: Color(0xFF1B1E2E),
  searchHitBackground: Color(0xFFF2B84B),
  searchHitBackgroundCurrent: Color(0xFF3FCF8E),
  searchHitForeground: Color(0xFF1B1E2E),
);
