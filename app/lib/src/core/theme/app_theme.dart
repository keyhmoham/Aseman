import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData get dark => _theme(Brightness.dark, AppColors.primary);
  static ThemeData get light => _theme(Brightness.light, AppColors.primary);
  static ThemeData darkWith(Color accent) => _theme(Brightness.dark, accent);
  static ThemeData lightWith(Color accent) => _theme(Brightness.light, accent);

  static ThemeData _theme(Brightness brightness, Color accent) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: dark ? const Color(0xFF111119) : const Color(0xFFF8F7FC),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF08080D) : const Color(0xFFF1F0F7),
      fontFamily: 'sans-serif',
      textTheme: (dark ? ThemeData.dark() : ThemeData.light())
          .textTheme
          .apply(fontFamily: 'sans-serif'),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF181822) : Colors.white,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide(color: scheme.outlineVariant)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide(color: scheme.outlineVariant)),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: AppColors.navigation,
        height: 66,
      ),
      dividerTheme: const DividerThemeData(color: AppColors.border),
      cardTheme: CardThemeData(
          color: scheme.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: .55)))),
    );
  }
}
