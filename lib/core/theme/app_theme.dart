import 'package:flutter/material.dart';

class FleetTheme {
  static const bg = Color(0xFF0B1220);
  static const card = Color(0xFF121A2B);
  static const cardAlt = Color(0xFF182236);
  static const line = Color(0xFF243049);
  static const text = Color(0xFFE7EEF8);
  static const muted = Color(0xFF8AA0B8);
  static const accent = Color(0xFF2DD4BF);
  static const warning = Color(0xFFF5A524);
  static const critical = Color(0xFFEF4444);
  static const moving = Color(0xFF34D399);
  static const idle = Color(0xFF60A5FA);
  static const stopped = Color(0xFFF97316);
  static const offline = Color(0xFF64748B);

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        surface: bg,
        onSurface: text,
        error: critical,
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: line),
        ),
      ),
      dividerColor: line,
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cardAlt,
        contentTextStyle: const TextStyle(color: text),
        actionTextColor: accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
