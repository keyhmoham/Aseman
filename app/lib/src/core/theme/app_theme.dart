import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_shape.dart';

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
    return _expressive(ThemeData(
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
    ));
  }
}

/// Material 3 Expressive refinements applied to the whole app: pill buttons
/// and chips, rounder dialogs, sheets and fields, floating snackbars, and the
/// 2024 slider and progress styles.
ThemeData _expressive(ThemeData base) {
  final scheme = base.colorScheme;
  // Derive every text style from the app's own so it keeps its font family.
  final label = base.textTheme.labelLarge ?? const TextStyle();
  const stadium = StadiumBorder();
  final pill = ButtonStyle(
    shape: const WidgetStatePropertyAll(stadium),
    padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
    textStyle: WidgetStatePropertyAll(
        label.copyWith(fontWeight: FontWeight.w700, fontSize: 14)),
  );
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShape.control),
          borderSide: BorderSide(color: color, width: width));
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(style: pill),
    outlinedButtonTheme: OutlinedButtonThemeData(style: pill),
    textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
            shape: const WidgetStatePropertyAll(stadium),
            textStyle: WidgetStatePropertyAll(
                label.copyWith(fontWeight: FontWeight.w700)))),
    chipTheme: base.chipTheme.copyWith(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: label.copyWith(fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(
            label.copyWith(fontWeight: FontWeight.w700, fontSize: 13)),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.card)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppShape.card))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.control)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.control)),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: .55),
      border: border(Colors.transparent),
      enabledBorder: border(Colors.transparent),
      focusedBorder: border(scheme.primary, 2),
      errorBorder: border(scheme.error),
      focusedErrorBorder: border(scheme.error, 2),
    ),
    // ignore: deprecated_member_use
    sliderTheme: base.sliderTheme.copyWith(year2023: false),
    // ignore: deprecated_member_use
    progressIndicatorTheme:
        base.progressIndicatorTheme.copyWith(year2023: false),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(10)),
      textStyle: label.copyWith(
          color: scheme.onInverseSurface,
          fontSize: 12,
          fontWeight: FontWeight.w500),
    ),
  );
}
