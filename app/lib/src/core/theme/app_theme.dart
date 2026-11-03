import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_shape.dart';
import 'app_surfaces.dart';
import 'aseman_tokens.dart';
import 'default_theme_packs.dart';
import 'design_language.dart';
import 'theme_chrome.dart';
import 'theme_pack.dart';

abstract final class AppTheme {
  static ThemeData get dark =>
      fromPack(DefaultThemePacks.sky, Brightness.dark);
  static ThemeData get light =>
      fromPack(DefaultThemePacks.sky, Brightness.light);

  static ThemeData darkWith(
    Color accent, {
    ThemePack? pack,
    String? paletteId,
  }) =>
      fromPack(
        pack ?? DefaultThemePacks.sky,
        Brightness.dark,
        accent: accent,
        paletteId: paletteId,
      );

  static ThemeData lightWith(
    Color accent, {
    ThemePack? pack,
    String? paletteId,
  }) =>
      fromPack(
        pack ?? DefaultThemePacks.sky,
        Brightness.light,
        accent: accent,
        paletteId: paletteId,
      );

  /// Builds Material [ThemeData] + [AsemanTokens] from an installable pack.
  ///
  /// Color accents come from the pack's [ThemePaletteOption] list (settings
  /// swatches). A matching [paletteId] wins; otherwise [accent] is matched or
  /// applied as a one-off custom overlay.
  static ThemeData fromPack(
    ThemePack pack,
    Brightness brightness, {
    Color? accent,
    String? paletteId,
  }) {
    final dark = brightness == Brightness.dark;
    final baseTokens = pack.tokens.forBrightness(brightness);
    final palette = _resolvePalette(pack, paletteId: paletteId, accent: accent);
    final tokens = baseTokens.overlayPalette(palette);
    final seed = palette.accent;
    final surface = tokens.surface ??
        (dark ? const Color(0xFF111119) : const Color(0xFFF7F7F9));
    final pageScaffold = tokens.scaffold ??
        (dark ? const Color(0xFF08080D) : const Color(0xFFF1F0F4));
    final surfaceHigh = tokens.surfaceHigh ??
        Color.alphaBlend(
          (dark ? Colors.white : Colors.black).withValues(alpha: dark ? .06 : .04),
          surface,
        );
    // Seed only the accent roles — keep surfaces neutral so the whole UI
    // does not wash pink/violet/teal when a colourful palette is selected.
    final seeded = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      surface: surface,
    );
    final onSurf = seeded.onSurface;
    Color nest(double a) =>
        Color.alphaBlend(onSurf.withValues(alpha: a), surface);
    final unified = pack.parts.unified || pack.parts.overrides.isEmpty;
    // Unified packs: one brand accent for primary + secondary decorative roles.
    final secondary = unified
        ? seed
        : (tokens.secondaryAccent ?? seeded.secondary);
    final scheme = seeded.copyWith(
      primary: seed,
      secondary: secondary,
      error: tokens.danger ?? seeded.error,
      surface: surface,
      surfaceTint: Colors.transparent,
      surfaceContainerLowest: pageScaffold,
      surfaceContainerLow: nest(dark ? .04 : .03),
      surfaceContainer: nest(dark ? .06 : .045),
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: nest(dark ? .10 : .07),
      primaryContainer: Color.alphaBlend(seed.withValues(alpha: .14), surface),
      onPrimaryContainer: dark
          ? seed
          : Color.alphaBlend(seed.withValues(alpha: .72), onSurf),
      secondaryContainer: Color.alphaBlend(
        secondary.withValues(alpha: .12),
        surface,
      ),
      tertiaryContainer: Color.alphaBlend(
        (tokens.success ?? seeded.tertiary).withValues(alpha: .12),
        surface,
      ),
      errorContainer: Color.alphaBlend(
        (tokens.danger ?? seeded.error).withValues(alpha: .12),
        surface,
      ),
    );
    final extension = AsemanTokens.fromTokens(
      packId: pack.id,
      tokens: tokens,
      language: pack.language,
      graphics: pack.graphics,
      shell: pack.shell,
      components: pack.components,
      bridges: pack.bridges,
      parts: pack.parts,
      ui: pack.ui,
      accent: seed,
    );
    final baseText = (dark ? ThemeData.dark() : ThemeData.light()).textTheme;
    FontWeight titleW = FontWeight.w800;
    FontWeight labelW = FontWeight.w700;
    try {
      titleW = FontWeight.values.firstWhere(
        (w) => w.value == tokens.titleWeight,
        orElse: () => FontWeight.w800,
      );
      labelW = FontWeight.values.firstWhere(
        (w) => w.value == tokens.labelWeight,
        orElse: () => FontWeight.w700,
      );
    } catch (_) {}
    final family =
        tokens.fontFamily.isEmpty ? null : tokens.fontFamily;
    TextStyle? styled(TextStyle? s, {FontWeight? weight, double? ls}) =>
        s?.copyWith(
          fontWeight: weight,
          letterSpacing: ls,
          fontFamily: family,
          height: s.height,
        );
    final textTheme = baseText.copyWith(
      displaySmall: styled(baseText.displaySmall,
          weight: titleW, ls: tokens.letterSpacingDisplay)
          ?.copyWith(height: 1.1),
      headlineMedium: styled(baseText.headlineMedium,
          weight: titleW, ls: tokens.letterSpacingDisplay * .75)
          ?.copyWith(height: 1.12),
      headlineSmall: styled(baseText.headlineSmall,
          weight: titleW, ls: tokens.letterSpacingTitle)
          ?.copyWith(height: 1.15),
      titleLarge: styled(baseText.titleLarge,
          weight: titleW, ls: tokens.letterSpacingTitle)
          ?.copyWith(height: 1.2),
      titleMedium: styled(baseText.titleMedium,
          weight: labelW, ls: tokens.letterSpacingTitle * .6)
          ?.copyWith(height: 1.25),
      titleSmall: styled(baseText.titleSmall,
          weight: labelW, ls: tokens.letterSpacingTitle * .4)
          ?.copyWith(height: 1.25),
      bodyLarge: styled(baseText.bodyLarge)?.copyWith(height: 1.4),
      bodyMedium: styled(baseText.bodyMedium)?.copyWith(height: 1.4),
      labelLarge: styled(baseText.labelLarge, weight: labelW),
    );
    final inputFill = tokens.inputFill ??
        (dark ? const Color(0xFF181822) : Colors.white);
    final controlR = tokens.radiusControl;
    final cardR = tokens.radiusCard;
    return _expressive(
      ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: scheme,
        scaffoldBackgroundColor: pageScaffold,
        applyElevationOverlayColor: false,
        textTheme: textTheme,
        extensions: [extension],
        visualDensity: VisualDensity(
          horizontal: tokens.density,
          vertical: tokens.density,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: inputFill,
          hintStyle: TextStyle(color: scheme.onSurfaceVariant),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(controlR == AppShape.control
                  ? 24
                  : controlR),
              borderSide: BorderSide(color: scheme.outlineVariant)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(controlR == AppShape.control
                  ? 24
                  : controlR),
              borderSide: BorderSide(color: scheme.outlineVariant)),
        ),
        dividerTheme: DividerThemeData(
            color: scheme.outlineVariant.withValues(alpha: .55), space: 1),
        cardTheme: CardThemeData(
            color: AppSurfaces.card(scheme, tokens: extension),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(cardR),
                side: BorderSide(
                    color: AppSurfaces.cardBorder(scheme)))),
      ),
      tokens: extension,
    );
  }
}

ThemePaletteOption _resolvePalette(
  ThemePack pack, {
  String? paletteId,
  Color? accent,
}) {
  if (paletteId != null && paletteId.isNotEmpty) {
    for (final opt in pack.selectablePalettes) {
      if (opt.id == paletteId) return opt;
    }
  }
  if (accent != null) {
    for (final opt in pack.selectablePalettes) {
      if (opt.accent.toARGB32() == accent.toARGB32()) return opt;
    }
    return ThemePaletteOption(
      id: 'custom',
      label: 'Custom',
      accent: accent,
    );
  }
  return pack.defaultPalette;
}

/// Applies the pack's [DesignLanguage] control recipes across Material chrome
/// so installed themes can reshape buttons/chips/inputs/dialogs like Material,
/// Fluent, Cupertino, neo-brutal, glass, or a fully custom language.
ThemeData _expressive(ThemeData base, {required AsemanTokens tokens}) {
  final scheme = base.colorScheme;
  final label = base.textTheme.labelLarge ?? const TextStyle();
  final lang = tokens.language;
  final button = tokens.control('button');
  final chip = tokens.control('chip');
  final input = tokens.control('input');
  final card = tokens.control('card');
  final sheet = tokens.control('sheet');
  final fab = tokens.control('fab');
  final dialog = tokens.control('dialog');
  final menu = tokens.control('menu');
  final nav = tokens.control('nav_pill');
  final slider = tokens.control('slider');
  final overlay = AppSurfaces.overlay(scheme, tokens: tokens);
  final borderColor = AppSurfaces.cardBorder(scheme);
  final buttonShape = button.border(sideColor: scheme.outline);
  final menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(overlay),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStatePropertyAll(menu.elevation),
    shape: WidgetStatePropertyAll(
        menu.border(sideColor: borderColor)),
  );
  final buttonStyle = ThemeChrome.buttonStyle(base, tokens: tokens);
  final iconStyle = ThemeChrome.iconButtonStyle(base, tokens: tokens);
  OutlineInputBorder fieldBorder(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: input.borderRadius,
        borderSide: BorderSide(
          color: color,
          width: width > 0 ? width : (input.borderWidth <= 0 ? 1 : input.borderWidth),
        ),
      );
  final dialogShape = dialog.border(sideColor: borderColor);
  final sheetShape = sheet.shape == ShapeKind.sharp
      ? const RoundedRectangleBorder()
      : RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(
                  sheet.radius <= 0 ? tokens.radiusCard : sheet.radius)),
        );
  final navIndicator = Color.alphaBlend(
    scheme.primary.withValues(
        alpha: scheme.brightness == Brightness.dark ? .22 : .12),
    scheme.surface.withValues(
        alpha: scheme.brightness == Brightness.dark ? .55 : .88),
  );
  return base.copyWith(
    extensions: [tokens],
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
            shape: WidgetStatePropertyAll(buttonShape),
            splashFactory: _inkFactory(lang.interaction.ink),
            textStyle: WidgetStatePropertyAll(
                label.copyWith(fontWeight: FontWeight.w700)))),
    iconButtonTheme: IconButtonThemeData(style: iconStyle),
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (context) => Icon(
        Icons.arrow_back_rounded,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      closeButtonIconBuilder: (context) => Icon(
        Icons.close_rounded,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: tokens.danger,
      textColor: scheme.onError,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      largeSize: 18,
      smallSize: 8,
      textStyle: label.copyWith(fontSize: 10, fontWeight: FontWeight.w800),
      alignment: AlignmentDirectional.topEnd,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: overlay,
      elevation: nav.elevation,
      height: tokens.navHeight,
      indicatorColor: navIndicator,
      indicatorShape: nav.border(sideColor: scheme.primary),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return label.copyWith(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: button.borderRadius),
      selectedTileColor: scheme.primary.withValues(alpha: .16),
      selectedColor: tokens.cyan,
      iconColor: scheme.onSurfaceVariant,
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: chip.border(sideColor: scheme.outlineVariant),
      side: chip.borderWidth > 0
          ? BorderSide(
              color: scheme.outlineVariant.withValues(alpha: chip.borderAlpha),
              width: chip.borderWidth)
          : BorderSide(color: scheme.outlineVariant),
      labelStyle: label.copyWith(fontWeight: FontWeight.w600),
      padding: EdgeInsets.symmetric(
          horizontal: chip.paddingH, vertical: chip.paddingV),
      selectedColor: scheme.primary.withValues(alpha: .18),
      secondarySelectedColor: tokens.cyan.withValues(alpha: .18),
      checkmarkColor: scheme.primary,
      deleteIconColor: scheme.onSurfaceVariant,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(buttonShape),
        textStyle: WidgetStatePropertyAll(
            label.copyWith(fontWeight: FontWeight.w700, fontSize: 13)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(
            horizontal: button.paddingH * .7, vertical: button.paddingV * .85)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dialog.fill == FillKind.glass ? overlay : scheme.surface,
      surfaceTintColor: Colors.transparent,
      barrierColor: tokens.barrier,
      elevation: dialog.elevation,
      shape: dialogShape,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      modalBackgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: tokens.barrier,
      showDragHandle: true,
      shape: sheetShape,
      elevation: sheet.elevation,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrimColor: tokens.barrier,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
            right: Radius.circular(
                card.radius <= 0 ? tokens.radiusCard : card.radius)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: overlay,
      surfaceTintColor: Colors.transparent,
      elevation: menu.elevation,
      shape: menu.border(sideColor: borderColor),
    ),
    menuTheme: MenuThemeData(style: menuStyle),
    dropdownMenuTheme: DropdownMenuThemeData(menuStyle: menuStyle),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: button.border(),
    ),
    cardTheme: CardThemeData(
      color: card.fill == FillKind.glass
          ? AppSurfaces.card(scheme, tokens: tokens)
          : scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: card.elevation,
      shape: card.border(sideColor: borderColor),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: input.fill == FillKind.solid
          ? scheme.surface
          : scheme.surfaceContainerHighest
              .withValues(alpha: tokens.cardAlpha * .7),
      border: fieldBorder(
          input.borderWidth > 0 ? scheme.outlineVariant : Colors.transparent,
          input.borderWidth > 0 ? input.borderWidth : 1),
      enabledBorder: fieldBorder(
          input.borderWidth > 0
              ? scheme.outlineVariant.withValues(alpha: input.borderAlpha)
              : Colors.transparent,
          input.borderWidth > 0 ? input.borderWidth : 1),
      focusedBorder: fieldBorder(scheme.primary, 2),
      errorBorder: fieldBorder(scheme.error, input.borderWidth > 0 ? input.borderWidth : 1),
      focusedErrorBorder: fieldBorder(scheme.error, 2),
    ),
    switchTheme: ThemeChrome.switchTheme(scheme, tokens: tokens),
    checkboxTheme: ThemeChrome.checkboxTheme(scheme, tokens: tokens),
    radioTheme: ThemeChrome.radioTheme(scheme, tokens: tokens),
    // ignore: deprecated_member_use
    sliderTheme: ThemeChrome.sliderTheme(scheme, tokens: tokens)
        .copyWith(year2023: false),
    // ignore: deprecated_member_use
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
      linearMinHeight: slider.minHeight ?? 4,
      year2023: false,
      borderRadius: slider.borderRadius,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: input.borderRadius),
      textStyle: label.copyWith(
          color: scheme.onInverseSurface,
          fontSize: 12,
          fontWeight: FontWeight.w500),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: fab.fill == FillKind.solid
          ? scheme.primaryContainer
          : AppFab.mistOf(scheme, tokens: tokens),
      foregroundColor: fab.fill == FillKind.solid
          ? scheme.onPrimaryContainer
          : AppFab.inkOf(scheme),
      focusColor: scheme.primary.withValues(alpha: .12),
      hoverColor: scheme.primary.withValues(alpha: lang.interaction.hoverAlpha),
      splashColor: scheme.primary.withValues(alpha: .12),
      elevation: fab.elevation,
      focusElevation: fab.elevation,
      hoverElevation: fab.elevation,
      highlightElevation: fab.elevation,
      disabledElevation: 0,
      enableFeedback: lang.interaction.ink != InkKind.none,
      shape: fab.border(sideColor: scheme.primary),
      extendedIconLabelSpacing: 10,
      extendedPadding: EdgeInsetsDirectional.only(
          start: fab.paddingH, end: fab.paddingH + 4),
      extendedTextStyle:
          label.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
    ),
  );
}

InteractiveInkFeatureFactory? _inkFactory(InkKind ink) => switch (ink) {
      InkKind.ripple => null, // Material default
      InkKind.highlight => NoSplash.splashFactory,
      InkKind.none => NoSplash.splashFactory,
    };

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
  static Color mistOf(
    ColorScheme scheme, {
    bool danger = false,
    AsemanTokens? tokens,
  }) {
    final accent = danger ? scheme.error : scheme.primary;
    final wash = tokens?.fabMistAlpha ??
        (scheme.brightness == Brightness.dark ? .24 : .14);
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
    double? radius,
    bool danger = false,
    AsemanTokens? tokens,
  }) {
    final fab = tokens?.control('fab');
    if (fab != null && radius == null) {
      return fab.border(sideColor: rimOf(scheme, danger: danger));
    }
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.all(
          Radius.circular(radius ?? tokens?.radiusFab ?? AppShape.fab)),
      side: BorderSide(color: rimOf(scheme, danger: danger)),
    );
  }

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
  ///
  /// Honors the pack FAB [FillKind]: solid / outline / glass stay flat;
  /// gradient keeps the Sky mist wash.
  static Decoration decorationOf(
    ColorScheme scheme, {
    double? radius,
    bool danger = false,
    bool glow = true,
    AsemanTokens? tokens,
  }) {
    final mist = mistOf(scheme, danger: danger, tokens: tokens);
    final fab = tokens?.control('fab');
    final rim = rimOf(scheme, danger: danger);
    final fillKind = fab?.fill ?? FillKind.gradient;
    final recipe = fab == null
        ? ControlRecipe(
            shape: ShapeKind.rounded,
            radius: radius ?? tokens?.radiusFab ?? AppShape.fab,
            borderWidth: 1,
          )
        : (radius != null ? fab.copyWith(radius: radius) : fab);
    final shape = ThemeChrome.outlinedBorder(
      recipe,
      sideColor: rim,
      borderWidth: recipe.borderWidth > 0
          ? recipe.borderWidth
          : (fillKind == FillKind.outline ? 1.5 : 0),
    );
    final shadows = glow
        ? (tokens?.language.shadow.resolve(scheme,
                accent: danger ? scheme.error : scheme.primary) ??
            glowOf(scheme, danger: danger))
        : null;
    final cyan = tokens?.cyan ?? AppColors.cyan;
    switch (fillKind) {
      case FillKind.solid:
        return ShapeDecoration(
          color: mist,
          shape: shape,
          shadows: shadows,
        );
      case FillKind.outline:
      case FillKind.text:
        return ShapeDecoration(
          color: Colors.transparent,
          shape: shape,
          shadows: shadows,
        );
      case FillKind.glass:
      case FillKind.tonal:
        return ShapeDecoration(
          color: mist.withValues(alpha: scheme.brightness == Brightness.dark
              ? .55
              : .72),
          shape: shape,
          shadows: shadows,
        );
      case FillKind.gradient:
        // ShapeDecoration has no gradient; fall back to rounded BoxDecoration
        // when the recipe is not cut (cut packs use solid above via tokens).
        if (recipe.shape == ShapeKind.cut || recipe.shape == ShapeKind.sharp) {
          return ShapeDecoration(
            color: mist,
            shape: shape,
            shadows: shadows,
          );
        }
        return BoxDecoration(
          borderRadius: recipe.borderRadius,
          border: recipe.borderWidth > 0
              ? Border.all(
                  color: rim.withValues(alpha: recipe.borderAlpha),
                  width: recipe.borderWidth,
                )
              : Border.all(color: rim),
          boxShadow: shadows,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              mist,
              Color.alphaBlend(
                (danger ? scheme.error : cyan).withValues(
                  alpha: scheme.brightness == Brightness.dark ? .10 : .06,
                ),
                mist,
              ),
            ],
          ),
        );
    }
  }

  /// Soft selected-tab pill used by [SegmentedTabBar] / [HomeTabBar].
  static BoxDecoration tabIndicatorOf(
    ColorScheme scheme, {
    double? radius,
    AsemanTokens? tokens,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    final nav = tokens?.control('nav_pill');
    final r = radius ?? nav?.radius ?? 22;
    final corners = nav?.borderRadius ?? BorderRadius.circular(r);
    return BoxDecoration(
      color: Color.alphaBlend(
        scheme.primary.withValues(alpha: dark ? .22 : .12),
        scheme.surface.withValues(alpha: dark ? .55 : .88),
      ),
      borderRadius: corners,
      border: Border.all(
        color: nav != null && nav.borderWidth > 0
            ? rimOf(scheme).withValues(alpha: nav.borderAlpha)
            : rimOf(scheme),
        width: nav != null && nav.borderWidth > 0 ? nav.borderWidth : 1,
      ),
      boxShadow: tokens?.language.shadow.resolve(scheme, accent: scheme.primary) ??
          [
            BoxShadow(
              color: scheme.primary.withValues(alpha: dark ? .18 : .10),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
    );
  }

  static Color backgroundOf(BuildContext context, {bool danger = false}) =>
      mistOf(Theme.of(context).colorScheme,
          danger: danger, tokens: AsemanTokens.maybeOf(context));

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
    final tokens = AsemanTokens.maybeOf(context);
    final fab = tokens?.control('fab');
    final radius = mini
        ? (tokens?.radiusFabSmall ?? AppShape.fabSmall)
        : (fab?.radius ?? tokens?.radiusFab ?? AppShape.fab);
    final ink = AppFab.inkOf(scheme, danger: danger);
    final iconSz = tokens?.language.iconSize ?? (mini ? 20 : 22);
    final pad = label == null
        ? EdgeInsets.all(mini ? 10 : (fab?.paddingV ?? 14))
        : EdgeInsets.fromLTRB(
            mini ? 12 : (fab?.paddingH ?? 14),
            mini ? 10 : (fab?.paddingV ?? 12),
            mini ? 14 : ((fab?.paddingH ?? 14) + 4),
            mini ? 10 : (fab?.paddingV ?? 12),
          );
    final body = IconTheme.merge(
      data: IconThemeData(color: ink, size: mini ? 20 : iconSz),
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
    final inkKind = fab?.ink ??
        tokens?.language.interaction.ink ??
        InkKind.ripple;
    final shape = AppFab.shapeOf(
      scheme,
      radius: mini ? radius : null,
      danger: danger,
      tokens: tokens,
    );
    Widget button = Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: shape,
      child: InkWell(
        onTap: onPressed,
        customBorder: shape,
        splashFactory: ThemeChrome.splashFactory(context, ink: inkKind),
        splashColor: ThemeChrome.pressSplash(
          context,
          accent: ink,
          ink: inkKind,
        ),
        highlightColor: ThemeChrome.pressHighlight(
          context,
          accent: ink,
          ink: inkKind,
        ),
        child: Ink(
          decoration: AppFab.decorationOf(
            scheme,
            radius: mini ? radius : null,
            danger: danger,
            glow: false,
            tokens: tokens,
          ),
          child: body,
        ),
      ),
    );
    button = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: tokens?.language.shadow.resolve(scheme,
                accent: danger ? scheme.error : scheme.primary) ??
            AppFab.glowOf(scheme, danger: danger),
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
