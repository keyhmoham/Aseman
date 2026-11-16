import 'package:flutter/material.dart';

import '../layout/app_layout.dart';
import 'app_shape.dart';
import 'app_surfaces.dart';
import 'aseman_tokens.dart';
import 'default_theme_packs.dart';
import 'design_language.dart';
import 'theme_chrome.dart';
import 'theme_pack.dart';

abstract final class AppTheme {
  static ThemeData get dark =>
      fromPack(DefaultThemePacks.paper, Brightness.dark);
  static ThemeData get light =>
      fromPack(DefaultThemePacks.paper, Brightness.light);

  static ThemeData darkWith(
    Color accent, {
    ThemePack? pack,
    String? paletteId,
  }) => fromPack(
    pack ?? DefaultThemePacks.paper,
    Brightness.dark,
    accent: accent,
    paletteId: paletteId,
  );

  static ThemeData lightWith(
    Color accent, {
    ThemePack? pack,
    String? paletteId,
  }) => fromPack(
    pack ?? DefaultThemePacks.paper,
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
    final paperPack = pack.id == DefaultThemePacks.paperId;
    final surface =
        tokens.surface ??
        (dark ? const Color(0xFF111119) : const Color(0xFFF7F7F9));
    final pageScaffold =
        tokens.scaffold ??
        (dark ? const Color(0xFF08080D) : const Color(0xFFF1F0F4));
    final surfaceHigh =
        tokens.surfaceHigh ??
        Color.alphaBlend(
          (dark ? Colors.white : Colors.black).withValues(
            alpha: dark ? .06 : .04,
          ),
          surface,
        );
    // Sky and the other packs keep a single brand accent on neutral surfaces.
    // Paper builds every role from the accent's own hue: darker primary,
    // lighter containers, and accent-tinted surface steps. Tertiary stays on
    // that hue (a deeper tone) so it does not jump to a complementary color.
    late final ColorScheme scheme;
    late final Color seed;
    if (paperPack) {
      final tonal = ColorScheme.fromSeed(
        seedColor: palette.accent,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
      );
      final dangerSeed = tokens.danger ?? tonal.error;
      final danger = ColorScheme.fromSeed(
        seedColor: dangerSeed,
        brightness: brightness,
      );
      seed = tonal.primary;
      final deeper = Color.lerp(
        tonal.primary,
        dark ? tonal.primaryFixedDim : tonal.onPrimaryContainer,
        dark ? .35 : .4,
      )!;
      scheme = tonal.copyWith(
        surfaceTint: tonal.primary,
        tertiary: deeper,
        onTertiary: dark ? tonal.onPrimary : tonal.onPrimaryContainer,
        tertiaryContainer: tonal.primaryContainer,
        onTertiaryContainer: tonal.onPrimaryContainer,
        tertiaryFixed: tonal.primaryFixed,
        tertiaryFixedDim: tonal.primaryFixedDim,
        onTertiaryFixed: tonal.onPrimaryFixed,
        onTertiaryFixedVariant: tonal.onPrimaryFixedVariant,
        error: danger.error,
        onError: danger.onError,
        errorContainer: danger.errorContainer,
        onErrorContainer: danger.onErrorContainer,
      );
    } else {
      seed = palette.accent;
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
      scheme = seeded.copyWith(
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
        // M3 Expressive container roles: soft accent tonal in light, quieter
        // mid-tone in dark (FAB default = primary-container; tonal buttons /
        // nav indicators = secondary-container). Never full primary wash.
        primaryContainer: Color.alphaBlend(
          seed.withValues(alpha: dark ? .26 : .14),
          surface,
        ),
        onPrimaryContainer: dark
            ? seed
            : Color.alphaBlend(seed.withValues(alpha: .72), onSurf),
        secondaryContainer: Color.alphaBlend(
          secondary.withValues(alpha: dark ? .26 : .14),
          surface,
        ),
        onSecondaryContainer: dark
            ? secondary
            : Color.alphaBlend(secondary.withValues(alpha: .72), onSurf),
        tertiaryContainer: Color.alphaBlend(
          (tokens.success ?? seeded.tertiary).withValues(
            alpha: dark ? .26 : .14,
          ),
          surface,
        ),
        onTertiaryContainer: dark
            ? (tokens.success ?? seeded.tertiary)
            : Color.alphaBlend(
                (tokens.success ?? seeded.tertiary).withValues(alpha: .72),
                onSurf,
              ),
        errorContainer: Color.alphaBlend(
          (tokens.danger ?? seeded.error).withValues(alpha: dark ? .26 : .14),
          surface,
        ),
        onErrorContainer: dark
            ? (tokens.danger ?? seeded.error)
            : Color.alphaBlend(
                (tokens.danger ?? seeded.error).withValues(alpha: .72),
                onSurf,
              ),
      );
    }
    var extension = AsemanTokens.fromTokens(
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
    if (paperPack) {
      // Decorative "cyan" spots take the secondary tone, not a copy of primary.
      extension = extension.copyWith(cyan: scheme.secondary, accent: seed);
    }
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
    final family = tokens.fontFamily.isEmpty ? null : tokens.fontFamily;
    TextStyle? styled(TextStyle? s, {FontWeight? weight, double? ls}) =>
        s?.copyWith(
          fontWeight: weight,
          letterSpacing: ls,
          fontFamily: family,
          height: s.height,
        );
    final textTheme = baseText.copyWith(
      displaySmall: styled(
        baseText.displaySmall,
        weight: titleW,
        ls: tokens.letterSpacingDisplay,
      )?.copyWith(height: 1.1),
      headlineMedium: styled(
        baseText.headlineMedium,
        weight: titleW,
        ls: tokens.letterSpacingDisplay * .75,
      )?.copyWith(height: 1.12),
      headlineSmall: styled(
        baseText.headlineSmall,
        weight: titleW,
        ls: tokens.letterSpacingTitle,
      )?.copyWith(height: 1.15),
      titleLarge: styled(
        baseText.titleLarge,
        weight: titleW,
        ls: tokens.letterSpacingTitle,
      )?.copyWith(height: 1.2),
      titleMedium: styled(
        baseText.titleMedium,
        weight: labelW,
        ls: tokens.letterSpacingTitle * .6,
      )?.copyWith(height: 1.25),
      titleSmall: styled(
        baseText.titleSmall,
        weight: labelW,
        ls: tokens.letterSpacingTitle * .4,
      )?.copyWith(height: 1.25),
      bodyLarge: styled(baseText.bodyLarge)?.copyWith(height: 1.4),
      bodyMedium: styled(baseText.bodyMedium)?.copyWith(height: 1.4),
      labelLarge: styled(baseText.labelLarge, weight: labelW),
    );
    final inputFill =
        tokens.inputFill ?? (dark ? const Color(0xFF181822) : Colors.white);
    final controlR = tokens.radiusControl;
    final cardR = tokens.radiusCard;
    return _expressive(
      ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: scheme,
        scaffoldBackgroundColor: paperPack ? scheme.surface : pageScaffold,
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
            borderRadius: BorderRadius.circular(
              controlR == AppShape.control ? 24 : controlR,
            ),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(
              controlR == AppShape.control ? 24 : controlR,
            ),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant.withValues(alpha: .55),
          space: 1,
        ),
        cardTheme: CardThemeData(
          color: pack.id == DefaultThemePacks.paperId
              ? surface
              : AppSurfaces.card(scheme, tokens: extension),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardR),
            side: BorderSide(color: AppSurfaces.cardBorder(scheme)),
          ),
        ),
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
    return ThemePaletteOption(id: 'custom', label: 'Custom', accent: accent);
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
  final paper = tokens.packId == DefaultThemePacks.paperId;
  final menuFill = paper ? scheme.surfaceContainerHigh : overlay;
  final navFill = paper ? scheme.surfaceContainer : overlay;
  final quiet = paper ? FontWeight.w500 : FontWeight.w700;
  final borderColor = AppSurfaces.cardBorder(scheme);
  final buttonShape = button.border(sideColor: scheme.outline);
  final menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(menuFill),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStatePropertyAll(menu.elevation),
    shape: WidgetStatePropertyAll(menu.border(sideColor: borderColor)),
  );
  final filledStyle = ThemeChrome.filledButtonStyle(base, tokens: tokens);
  final elevatedStyle = ThemeChrome.elevatedButtonStyle(base, tokens: tokens);
  final outlinedStyle = ThemeChrome.outlinedButtonStyle(base, tokens: tokens);
  final iconStyle = ThemeChrome.iconButtonStyle(base, tokens: tokens);
  OutlineInputBorder fieldBorder(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: input.borderRadius,
        borderSide: BorderSide(
          color: color,
          width: width > 0
              ? width
              : (input.borderWidth <= 0 ? 1 : input.borderWidth),
        ),
      );
  final dialogShape = dialog.border(sideColor: borderColor);
  final sheetShape = sheet.shape == ShapeKind.sharp
      ? const RoundedRectangleBorder()
      : RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(
              sheet.radius <= 0 ? tokens.radiusCard : sheet.radius,
            ),
          ),
        );
  return base.copyWith(
    extensions: [tokens],
    // M3 Expressive button colors: filled = primary/on-primary; tonal =
    // secondary-container; elevated = surface-container-low; outlined /
    // text keep low emphasis. Shape/padding still follow the pack recipe.
    filledButtonTheme: FilledButtonThemeData(style: filledStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: elevatedStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedStyle),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(buttonShape),
        foregroundColor: WidgetStatePropertyAll(scheme.primary),
        splashFactory: _inkFactory(lang.interaction.ink),
        textStyle: WidgetStatePropertyAll(
          label.copyWith(fontWeight: quiet),
        ),
      ),
    ),
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
      backgroundColor: navFill,
      elevation: nav.elevation,
      height: tokens.navHeight,
      // M3 Expressive: active indicator = secondary-container.
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: nav.border(),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return label.copyWith(
          fontSize: 11,
          fontWeight: selected ? (paper ? FontWeight.w500 : FontWeight.w700) : FontWeight.w500,
          // Vertical items: label sits below the pill → secondary.
          color: selected ? scheme.secondary : scheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          // Icon sits on the indicator → on-secondary-container.
          color: selected
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        );
      }),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      minWidth: AppLayout.navigationRailWidth,
      minExtendedWidth: AppLayout.extendedNavigationRailWidth,
      useIndicator: true,
      indicatorColor: scheme.secondaryContainer,
      selectedIconTheme: IconThemeData(
        size: 24,
        color: scheme.onSecondaryContainer,
      ),
      unselectedIconTheme: IconThemeData(
        size: 24,
        color: scheme.onSurfaceVariant,
      ),
      selectedLabelTextStyle: label.copyWith(
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: label.copyWith(
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
      indicatorShape: const StadiumBorder(),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: paper ? scheme.surfaceContainerLow : scheme.surface,
      surfaceTintColor: paper ? scheme.surfaceTint : Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(4),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
      thumbColor: WidgetStateProperty.resolveWith((states) {
        final alpha = states.contains(WidgetState.dragged)
            ? .65
            : states.contains(WidgetState.hovered)
            ? .5
            : .32;
        return scheme.onSurfaceVariant.withValues(alpha: alpha);
      }),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: button.borderRadius),
      selectedTileColor: paper
          ? scheme.secondaryContainer
          : scheme.primary.withValues(alpha: .16),
      selectedColor: paper ? scheme.onSecondaryContainer : tokens.cyan,
      iconColor: scheme.onSurfaceVariant,
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: chip.border(sideColor: scheme.outlineVariant),
      side: chip.borderWidth > 0
          ? BorderSide(
              color: scheme.outlineVariant.withValues(alpha: chip.borderAlpha),
              width: chip.borderWidth,
            )
          : BorderSide(color: scheme.outlineVariant),
      labelStyle: label.copyWith(fontWeight: FontWeight.w600),
      padding: EdgeInsets.symmetric(
        horizontal: chip.paddingH,
        vertical: chip.paddingV,
      ),
      backgroundColor: paper ? scheme.surfaceContainerHigh : null,
      selectedColor: paper
          ? scheme.secondaryContainer
          : scheme.primary.withValues(alpha: .18),
      secondarySelectedColor: paper
          ? scheme.secondaryContainer
          : tokens.cyan.withValues(alpha: .18),
      checkmarkColor: paper ? scheme.onSecondaryContainer : scheme.primary,
      deleteIconColor: scheme.onSurfaceVariant,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(buttonShape),
        textStyle: WidgetStatePropertyAll(
          label.copyWith(fontWeight: quiet, fontSize: 13),
        ),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(
            horizontal: button.paddingH * .7,
            vertical: button.paddingV * .85,
          ),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: paper
          ? scheme.surfaceContainerHigh
          : (dialog.fill == FillKind.glass ? overlay : scheme.surface),
      surfaceTintColor: paper ? scheme.surfaceTint : Colors.transparent,
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
            card.radius <= 0 ? tokens.radiusCard : card.radius,
          ),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: menuFill,
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
      color: paper
          ? scheme.surfaceContainerHigh
          : (card.fill == FillKind.glass
                ? AppSurfaces.card(scheme, tokens: tokens)
                : scheme.surface),
      surfaceTintColor: paper ? scheme.surfaceTint : Colors.transparent,
      elevation: card.elevation,
      shape: card.border(sideColor: borderColor),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: paper
          ? scheme.surfaceContainerHighest
          : (input.fill == FillKind.solid
                ? scheme.surface
                : scheme.surfaceContainerHighest.withValues(
                    alpha: tokens.cardAlpha * .7,
                  )),
      border: fieldBorder(
        input.borderWidth > 0 ? scheme.outlineVariant : Colors.transparent,
        input.borderWidth > 0 ? input.borderWidth : 1,
      ),
      enabledBorder: fieldBorder(
        input.borderWidth > 0
            ? scheme.outlineVariant.withValues(alpha: input.borderAlpha)
            : Colors.transparent,
        input.borderWidth > 0 ? input.borderWidth : 1,
      ),
      focusedBorder: fieldBorder(scheme.primary, 2),
      errorBorder: fieldBorder(
        scheme.error,
        input.borderWidth > 0 ? input.borderWidth : 1,
      ),
      focusedErrorBorder: fieldBorder(scheme.error, 2),
    ),
    switchTheme: ThemeChrome.switchTheme(scheme, tokens: tokens),
    checkboxTheme: ThemeChrome.checkboxTheme(scheme, tokens: tokens),
    radioTheme: ThemeChrome.radioTheme(scheme, tokens: tokens),
    // ignore: deprecated_member_use
    sliderTheme: ThemeChrome.sliderTheme(
      scheme,
      tokens: tokens,
    ).copyWith(year2023: false),
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
        borderRadius: input.borderRadius,
      ),
      textStyle: label.copyWith(
        color: scheme.onInverseSurface,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      // M3 Expressive default FAB: primary-container / on-primary-container.
      backgroundColor: AppFab.containerOf(scheme, tokens: tokens),
      foregroundColor: AppFab.inkOf(scheme, tokens: tokens),
      focusColor: AppFab.inkOf(scheme, tokens: tokens).withValues(alpha: .12),
      hoverColor: AppFab.inkOf(
        scheme,
        tokens: tokens,
      ).withValues(alpha: lang.interaction.hoverAlpha),
      splashColor: AppFab.inkOf(scheme, tokens: tokens).withValues(alpha: .12),
      elevation: fab.elevation > 0 ? fab.elevation : 3,
      focusElevation: fab.elevation > 0 ? fab.elevation : 3,
      hoverElevation: fab.elevation > 0 ? fab.elevation + 1 : 4,
      highlightElevation: fab.elevation > 0 ? fab.elevation : 3,
      disabledElevation: 0,
      enableFeedback: lang.interaction.ink != InkKind.none,
      shape: AppFab.shapeOf(scheme, tokens: tokens),
      extendedIconLabelSpacing: 10,
      extendedPadding: EdgeInsetsDirectional.only(
        start: fab.paddingH,
        end: fab.paddingH + 4,
      ),
      extendedTextStyle: label.copyWith(
        fontWeight: FontWeight.w700,
        fontSize: 14,
      ),
    ),
  );
}

InteractiveInkFeatureFactory? _inkFactory(InkKind ink) => switch (ink) {
  InkKind.ripple => null, // Material default
  InkKind.highlight => NoSplash.splashFactory,
  InkKind.none => NoSplash.splashFactory,
};

/// M3 Expressive floating actions — opaque primary-container / on-primary-
/// container (soft tonal in light, quieter mid-tone in dark). No mist wash,
/// hairline rim, or accent bloom. Prefer [SkyFab] when a hand-rolled capsule
/// is needed; stock [FloatingActionButton] reads the same theme roles.
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

  /// M3 Expressive FAB container: primary-container (or error-container).
  static Color containerOf(
    ColorScheme scheme, {
    bool danger = false,
    AsemanTokens? tokens,
  }) {
    if (danger) return scheme.errorContainer;
    final fab = tokens?.control('fab');
    return switch (fab?.fill) {
      FillKind.tonal => scheme.secondaryContainer,
      FillKind.outline || FillKind.text => Colors.transparent,
      _ => scheme.primaryContainer,
    };
  }

  /// Icon / label ink on [containerOf] — on-primary-container (or
  /// on-secondary-container when the pack FAB recipe is tonal).
  static Color inkOf(
    ColorScheme scheme, {
    bool danger = false,
    AsemanTokens? tokens,
  }) {
    if (danger) return scheme.onErrorContainer;
    final fab = tokens?.control('fab');
    return switch (fab?.fill) {
      FillKind.tonal => scheme.onSecondaryContainer,
      _ => scheme.onPrimaryContainer,
    };
  }

  /// @Deprecated Kept for call sites mid-migration; prefer [containerOf].
  static Color mistOf(
    ColorScheme scheme, {
    bool danger = false,
    AsemanTokens? tokens,
  }) => containerOf(scheme, danger: danger, tokens: tokens);

  /// Hairline only when the pack recipe asks for a border (e.g. neo-brutal).
  static Color? rimOf(
    ColorScheme scheme, {
    bool danger = false,
    AsemanTokens? tokens,
  }) {
    final fab = tokens?.control('fab');
    if (fab == null || fab.borderWidth <= 0) return null;
    final accent = danger ? scheme.error : scheme.primary;
    return accent.withValues(alpha: fab.borderAlpha);
  }

  static ShapeBorder shapeOf(
    ColorScheme scheme, {
    double? radius,
    bool danger = false,
    AsemanTokens? tokens,
  }) {
    final fab = tokens?.control('fab');
    final rim = rimOf(scheme, danger: danger, tokens: tokens);
    if (fab != null && radius == null) {
      return fab.border(sideColor: rim);
    }
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.all(
        Radius.circular(radius ?? tokens?.radiusFab ?? AppShape.fab),
      ),
      side: rim == null ? BorderSide.none : BorderSide(color: rim),
    );
  }

  /// Neutral depth under floating chrome (no accent bloom).
  static List<BoxShadow> glowOf(ColorScheme scheme, {bool danger = false}) {
    final dark = scheme.brightness == Brightness.dark;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? .28 : .10),
        blurRadius: 16,
        offset: const Offset(0, 6),
      ),
    ];
  }

  /// Opaque M3 container fill for hand-rolled FABs ([SkyFab]).
  static Decoration decorationOf(
    ColorScheme scheme, {
    double? radius,
    bool danger = false,
    bool glow = false,
    AsemanTokens? tokens,
  }) {
    final fill = containerOf(scheme, danger: danger, tokens: tokens);
    final fab = tokens?.control('fab');
    final recipe = fab == null
        ? ControlRecipe(
            shape: ShapeKind.rounded,
            radius: radius ?? tokens?.radiusFab ?? AppShape.fab,
          )
        : (radius != null ? fab.copyWith(radius: radius) : fab);
    final rim = rimOf(scheme, danger: danger, tokens: tokens);
    final shape = ThemeChrome.outlinedBorder(
      recipe,
      sideColor: rim,
      borderWidth: rim == null ? 0 : recipe.borderWidth,
    );
    final shadows = glow
        ? (tokens?.language.shadow.resolve(
                scheme,
                accent: danger ? scheme.error : scheme.primary,
              ) ??
              glowOf(scheme, danger: danger))
        : null;
    return ShapeDecoration(color: fill, shape: shape, shadows: shadows);
  }

  /// M3 Expressive selected-tab indicator ([SegmentedTabBar] / [HomeTabBar]):
  /// opaque [ColorScheme.secondaryContainer] — soft accent tonal in light,
  /// quieter accent mid-tone in dark (not full primary, no bubble chrome).
  static BoxDecoration tabIndicatorOf(
    ColorScheme scheme, {
    double? radius,
    AsemanTokens? tokens,
  }) {
    final nav = tokens?.control('nav_pill');
    final r = radius ?? nav?.radius ?? 22;
    final corners = nav?.borderRadius ?? BorderRadius.circular(r);
    return BoxDecoration(
      color: scheme.secondaryContainer,
      borderRadius: corners,
    );
  }

  /// Ink drawn on [tabIndicatorOf] — [ColorScheme.onSecondaryContainer].
  static Color tabIndicatorInkOf(ColorScheme scheme) =>
      scheme.onSecondaryContainer;

  static Color backgroundOf(BuildContext context, {bool danger = false}) =>
      containerOf(
        Theme.of(context).colorScheme,
        danger: danger,
        tokens: AsemanTokens.maybeOf(context),
      );

  static Color foregroundOf(BuildContext context, {bool danger = false}) =>
      inkOf(
        Theme.of(context).colorScheme,
        danger: danger,
        tokens: AsemanTokens.maybeOf(context),
      );
}

/// M3 Expressive floating action — solid primary-container capsule.
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
    final ink = AppFab.inkOf(scheme, danger: danger, tokens: tokens);
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
    final inkKind =
        fab?.ink ?? tokens?.language.interaction.ink ?? InkKind.ripple;
    final shape = AppFab.shapeOf(
      scheme,
      radius: mini ? radius : null,
      danger: danger,
      tokens: tokens,
    );
    final elevation = fab?.elevation ?? 0;
    final shadows = elevation > 0
        ? tokens?.language.shadow.resolve(
            scheme,
            accent: danger ? scheme.error : scheme.primary,
          )
        : null;
    Widget button = Material(
      color: AppFab.containerOf(scheme, danger: danger, tokens: tokens),
      elevation: elevation > 0 ? elevation : 3,
      shadowColor: scheme.shadow,
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
        child: body,
      ),
    );
    if (shadows != null && shadows.isNotEmpty) {
      button = DecoratedBox(
        decoration: ShapeDecoration(shape: shape, shadows: shadows),
        child: button,
      );
    }
    if (heroTag != null) {
      button = Hero(tag: heroTag!, child: button);
    }
    if (tooltip == null || tooltip!.isEmpty) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
