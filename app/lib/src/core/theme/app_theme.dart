import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_shape.dart';
import 'app_surfaces.dart';

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
    final baseText = (dark ? ThemeData.dark() : ThemeData.light()).textTheme;
    final textTheme = baseText.copyWith(
      displaySmall: baseText.displaySmall?.copyWith(
          fontWeight: FontWeight.w800, letterSpacing: -.8, height: 1.1),
      headlineMedium: baseText.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800, letterSpacing: -.6, height: 1.12),
      headlineSmall: baseText.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800, letterSpacing: -.5, height: 1.15),
      titleLarge: baseText.titleLarge?.copyWith(
          fontWeight: FontWeight.w800, letterSpacing: -.35, height: 1.2),
      titleMedium: baseText.titleMedium?.copyWith(
          fontWeight: FontWeight.w700, letterSpacing: -.2, height: 1.25),
      titleSmall: baseText.titleSmall?.copyWith(
          fontWeight: FontWeight.w700, letterSpacing: -.15, height: 1.25),
      bodyLarge: baseText.bodyLarge?.copyWith(height: 1.4),
      bodyMedium: baseText.bodyMedium?.copyWith(height: 1.4),
      labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    );
    return _expressive(ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF08080D) : const Color(0xFFF1F0F7),
      textTheme: textTheme,
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
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppSurfaces.overlay(scheme),
        height: 66,
      ),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant.withValues(alpha: .55), space: 1),
      // Translucent glass tint; prefer [AppCard] / [GlassSurface] when the
      // surface should also frost what sits behind it.
      cardTheme: CardThemeData(
          color: AppSurfaces.card(scheme),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppShape.card),
              side: BorderSide(color: AppSurfaces.cardBorder(scheme)))),
    ));
  }
}

/// Material 3 Expressive refinements applied to the whole app: pill buttons
/// and chips, rounder dialogs, sheets and fields, floating snackbars, tonal
/// FABs with size-adaptive corners, and the 2024 slider and progress styles.
ThemeData _expressive(ThemeData base) {
  final scheme = base.colorScheme;
  // Derive every text style from the app's own so it keeps its font family.
  final label = base.textTheme.labelLarge ?? const TextStyle();
  const stadium = StadiumBorder();
  final overlay = AppSurfaces.overlay(scheme);
  final menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(overlay),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.control))),
  );
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
    // Every modal surface shares one background, scrim and corner radius
    // (see AppSurfaces), so call sites never pass their own.
    dialogTheme: DialogThemeData(
      // [showAppDialog] paints [GlassSurface]; keep Dialog chrome clear so
      // raw AlertDialogs opened outside it still read as translucent glass.
      backgroundColor: overlay,
      surfaceTintColor: Colors.transparent,
      barrierColor: AppSurfaces.barrier,
      shape: AppSurfaces.overlayShape,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      // Prefer [showAppSheet]: it paints [GlassSurface] including the handle.
      // Theme chrome stays clear so Material's own handle is not drawn on a
      // translucent fill above the frost. Raw [showModalBottomSheet] callers
      // that need an opaque body must set backgroundColor themselves.
      backgroundColor: Colors.transparent,
      modalBackgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: AppSurfaces.barrier,
      showDragHandle: true,
      shape: AppSurfaces.sheetShape,
    ),
    drawerTheme: const DrawerThemeData(
      // [GlassDrawerSurface] paints the frost; Drawer chrome stays clear.
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrimColor: AppSurfaces.barrier,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
            right: Radius.circular(AppShape.card)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      // Prefer [AppPopupMenuButton] / [showAppMenu] for real blur; native
      // menus at least share the translucent overlay tint.
      color: overlay,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.control),
          side: BorderSide(color: AppSurfaces.cardBorder(scheme))),
    ),
    menuTheme: MenuThemeData(style: menuStyle),
    dropdownMenuTheme: DropdownMenuThemeData(menuStyle: menuStyle),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.control)),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: scheme.surfaceContainerHighest
          .withValues(alpha: AppSurfaces.cardAlpha * .7),
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
    // Soft mist FABs: quiet surface wash + hairline accent rim, no heavy
    // Material lift. Prefer [SkyFab] for the full glow treatment.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppFab.mistOf(scheme),
      foregroundColor: AppFab.inkOf(scheme),
      focusColor: scheme.primary.withValues(alpha: .12),
      hoverColor: scheme.primary.withValues(alpha: .08),
      splashColor: scheme.primary.withValues(alpha: .12),
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      disabledElevation: 0,
      enableFeedback: true,
      shape: AppFab.shapeOf(scheme),
      extendedIconLabelSpacing: 10,
      extendedPadding: const EdgeInsetsDirectional.only(start: 16, end: 20),
      extendedTextStyle:
          label.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
    ),
  );
}

/// Soft mist floating actions — translucent wash, hairline rim, accent ink.
///
/// Replaces solid `primaryContainer` FABs so floating actions match SoftCard /
/// glass language. Prefer [SkyFab] at call sites for the glow capsule.
abstract final class AppFab {
  /// Regular / extended FAB corner (16dp).
  static const ShapeBorder shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppShape.fab)),
  );

  /// Compact FAB-like controls (messenger compose chip, mini actions).
  static const ShapeBorder smallShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppShape.fabSmall)),
  );

  /// Large FAB corner (28dp).
  static const ShapeBorder largeShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppShape.fabLarge)),
  );

  /// Quiet accent mist over the page surface (not a solid container fill).
  static Color mistOf(ColorScheme scheme, {bool danger = false}) {
    final accent = danger ? scheme.error : scheme.primary;
    final wash = scheme.brightness == Brightness.dark ? .24 : .14;
    return Color.alphaBlend(
      accent.withValues(alpha: wash),
      scheme.surface,
    );
  }

  /// Icon / label ink on a mist FAB.
  static Color inkOf(ColorScheme scheme, {bool danger = false}) =>
      danger ? scheme.error : scheme.primary;

  /// Hairline rim keyed to the accent.
  static Color rimOf(ColorScheme scheme, {bool danger = false}) {
    final accent = danger ? scheme.error : scheme.primary;
    return accent.withValues(alpha: scheme.brightness == Brightness.dark
        ? .42
        : .30);
  }

  static ShapeBorder shapeOf(
    ColorScheme scheme, {
    double radius = AppShape.fab,
    bool danger = false,
  }) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        side: BorderSide(color: rimOf(scheme, danger: danger)),
      );

  /// Soft depth + accent bloom under the capsule.
  static List<BoxShadow> glowOf(ColorScheme scheme, {bool danger = false}) {
    final accent = danger ? scheme.error : scheme.primary;
    final dark = scheme.brightness == Brightness.dark;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? .30 : .08),
        blurRadius: 18,
        offset: const Offset(0, 8),
      ),
      BoxShadow(
        color: accent.withValues(alpha: dark ? .22 : .16),
        blurRadius: 22,
        spreadRadius: -2,
        offset: const Offset(0, 4),
      ),
    ];
  }

  /// Fill + rim for hand-rolled mist chips ([SkyFab], compose control).
  static BoxDecoration decorationOf(
    ColorScheme scheme, {
    double radius = AppShape.fab,
    bool danger = false,
    bool glow = true,
  }) {
    final mist = mistOf(scheme, danger: danger);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: rimOf(scheme, danger: danger)),
      boxShadow: glow ? glowOf(scheme, danger: danger) : null,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          mist,
          Color.alphaBlend(
            (danger ? scheme.error : AppColors.cyan).withValues(
              alpha: scheme.brightness == Brightness.dark ? .10 : .06,
            ),
            mist,
          ),
        ],
      ),
    );
  }

  /// Soft selected-tab pill used by [SegmentedTabBar] / [HomeTabBar].
  static BoxDecoration tabIndicatorOf(
    ColorScheme scheme, {
    double radius = 22,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    return BoxDecoration(
      color: Color.alphaBlend(
        scheme.primary.withValues(alpha: dark ? .22 : .12),
        scheme.surface.withValues(alpha: dark ? .55 : .88),
      ),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: rimOf(scheme)),
      boxShadow: [
        BoxShadow(
          color: scheme.primary.withValues(alpha: dark ? .18 : .10),
          blurRadius: 12,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  static Color backgroundOf(BuildContext context, {bool danger = false}) =>
      mistOf(Theme.of(context).colorScheme, danger: danger);

  static Color foregroundOf(BuildContext context, {bool danger = false}) =>
      inkOf(Theme.of(context).colorScheme, danger: danger);
}

/// Soft mist floating action — icon, or icon + label. Prefer this over a
/// stock [FloatingActionButton] so actions match SoftCard / glass chrome.
class SkyFab extends StatelessWidget {
  const SkyFab({
    super.key,
    required this.onPressed,
    this.icon,
    this.label,
    this.tooltip,
    this.heroTag,
    this.mini = false,
    this.danger = false,
  });

  final VoidCallback? onPressed;
  final IconData? icon;
  final String? label;
  final String? tooltip;
  final Object? heroTag;
  final bool mini;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = mini ? AppShape.fabSmall : AppShape.fab;
    final ink = AppFab.inkOf(scheme, danger: danger);
    final pad = label == null
        ? EdgeInsets.all(mini ? 10 : 14)
        : EdgeInsets.fromLTRB(mini ? 12 : 14, mini ? 10 : 12, mini ? 14 : 18,
            mini ? 10 : 12);
    final body = IconTheme.merge(
      data: IconThemeData(color: ink, size: mini ? 20 : 22),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: ink,
          fontWeight: FontWeight.w700,
          fontSize: mini ? 12.5 : 14,
          letterSpacing: -.1,
        ),
        child: Padding(
          padding: pad,
          child: label == null
              ? Icon(icon ?? Icons.add_rounded)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: mini ? 18 : 18),
                      SizedBox(width: mini ? 6 : 8),
                    ],
                    Text(label!),
                  ],
                ),
        ),
      ),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    Widget button = Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: shape,
      child: InkWell(
        onTap: onPressed,
        customBorder: shape,
        splashColor: ink.withValues(alpha: .12),
        highlightColor: ink.withValues(alpha: .06),
        child: Ink(
          decoration: AppFab.decorationOf(
            scheme,
            radius: radius,
            danger: danger,
            glow: false,
          ),
          child: body,
        ),
      ),
    );
    button = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: AppFab.glowOf(scheme, danger: danger),
      ),
      child: button,
    );
    if (heroTag != null) {
      button = Hero(tag: heroTag!, child: button);
    }
    if (tooltip == null || tooltip!.isEmpty) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
