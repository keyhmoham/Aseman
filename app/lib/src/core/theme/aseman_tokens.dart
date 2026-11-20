import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_surfaces.dart';
import 'default_theme_packs.dart';
import 'design_language.dart';
import 'shell_layout.dart';
import 'theme_pack.dart';
import 'theme_ui_spec.dart';

/// Host design tokens registered on [ThemeData.extensions].
///
/// Shared chrome (glass, sky, overlays) reads this extension instead of
/// hard-coded constants so installed theme packs can restyle the whole app.
@immutable
class AsemanTokens extends ThemeExtension<AsemanTokens> {
  const AsemanTokens({
    required this.packId,
    required this.cardAlpha,
    required this.overlayAlpha,
    required this.blurSigma,
    required this.barrier,
    required this.radiusCard,
    required this.radiusInner,
    required this.radiusControl,
    required this.radiusFab,
    required this.radiusFabSmall,
    required this.radiusFabLarge,
    required this.spacingScale,
    required this.density,
    required this.motionScale,
    required this.reduceMotion,
    required this.cyan,
    required this.success,
    required this.warning,
    required this.danger,
    required this.atmosphere,
    required this.haloStyle,
    required this.iconTreatment,
    required this.language,
    required this.shell,
    required this.components,
    required this.bridges,
    this.fabMistAlpha,
    this.navHeight = 66,
    this.accent = AppColors.primary,
    this.parts = const ThemePartColors(),
    this.ui = const ThemeUiSpec(),
  });

  final String packId;
  final double cardAlpha;
  final double overlayAlpha;
  final double blurSigma;
  final Color barrier;
  final double radiusCard;
  final double radiusInner;
  final double radiusControl;
  final double radiusFab;
  final double radiusFabSmall;
  final double radiusFabLarge;
  final double spacingScale;
  final double density;
  final double motionScale;
  final bool reduceMotion;
  final Color cyan;
  final Color success;
  final Color warning;
  final Color danger;
  final String atmosphere;
  final String haloStyle;
  final String iconTreatment;
  final DesignLanguage language;
  final ShellLayoutSpec shell;
  final Map<String, ComponentStyle> components;
  final ThemeBridges bridges;
  final double? fabMistAlpha;
  final double navHeight;

  /// Active palette accent (single brand colour when [parts.unified]).
  final Color accent;

  /// Pack part colour map (unified by default).
  final ThemePartColors parts;

  /// Disable / Elpian-extend shell slots.
  final ThemeUiSpec ui;

  /// Whether decorative accents collapse to [accent].
  bool get unifiedAccent => parts.unified || parts.overrides.isEmpty;

  Color partAccent(ThemePartId part) => parts.accentFor(part, accent);

  Color partSecondary(ThemePartId part) =>
      parts.secondaryFor(part, accent) ?? accent;

  bool slotDisabled(String slot) => ui.isDisabled(slot);

  ThemeSurfaceSpec? slotSurface(String slot) => ui.surfaceFor(slot);

  /// Resolves a control recipe and syncs it with pack token radii so Studio /
  /// token edits to `radius_card` / `radius_control` / `radius_fab` actually
  /// reshape buttons, bubbles, headers, and FABs — not only SoftCard.
  ControlRecipe control(String slot) {
    final override = components[slot];
    var recipe = language.resolve(slot, override);
    recipe = _alignFamilyShape(slot, recipe, override);
    if (override?.radius != null) return recipe;
    if (recipe.shape == ShapeKind.stadium) return recipe;
    if (recipe.shape == ShapeKind.sharp) {
      return recipe.copyWith(radius: 0);
    }
    final tokenR = _tokenRadiusFor(slot);
    if (tokenR == null) return recipe;
    return recipe.copyWith(radius: tokenR);
  }

  /// When the language makes cards/buttons sharp (neo-brutal) but leaves
  /// chat bubbles / app bars on the stock rounded recipe, follow the card.
  ControlRecipe _alignFamilyShape(
    String slot,
    ControlRecipe recipe,
    ComponentStyle? override,
  ) {
    if (override?.shapeKind != null) return recipe;
    final card = language.card;
    final button = language.button;
    final family = switch (slot) {
      'chat_bubble' || 'chatBubble' || 'panel_header' || 'panelHeader' ||
      'nav_pill' || 'navPill' || 'sheet' || 'bottom_sheet' || 'dialog' ||
      'menu' || 'popup' =>
        card,
      'fab' ||
      'chip' ||
      'input' ||
      'field' ||
      'toggle' ||
      'switch' ||
      'checkbox' ||
      'radio' ||
      'slider' ||
      'progress' ||
      'badge' ||
      'tab' ||
      'list_tile' ||
      'listTile' ||
      'avatar' ||
      'tooltip' =>
        button,
      _ => null,
    };
    if (family == null) return recipe;
    if (family.shape == recipe.shape) return recipe;
    // Only pull trailing slots onto a sharp / cut language; don't override
    // intentional stadium FABs/pills in glass/cupertino.
    if (family.shape != ShapeKind.sharp && family.shape != ShapeKind.cut) {
      return recipe;
    }
    return recipe.copyWith(
      shape: family.shape,
      radius: family.radius,
      borderWidth: recipe.borderWidth > 0 ? recipe.borderWidth : family.borderWidth,
      borderAlpha: family.borderAlpha,
    );
  }

  double? _tokenRadiusFor(String slot) => switch (slot) {
        'button' ||
        'filled_button' ||
        'outlined_button' ||
        'chip' ||
        'input' ||
        'field' =>
          radiusControl,
        'fab' => radiusFab,
        'card' ||
        'dialog' ||
        'sheet' ||
        'bottom_sheet' ||
        'panel_header' ||
        'panelHeader' ||
        'nav_pill' ||
        'navPill' ||
        'menu' ||
        'popup' =>
          radiusCard,
        'chat_bubble' || 'chatBubble' => radiusInner,
        _ => radiusInner,
      };

  static AsemanTokens? maybeOf(BuildContext context) =>
      Theme.of(context).extension<AsemanTokens>();

  static AsemanTokens of(BuildContext context) =>
      maybeOf(context) ?? defaults(Theme.of(context).brightness);

  static AsemanTokens defaults(Brightness brightness) =>
      fromPack(DefaultThemePacks.kashi, brightness);

  static AsemanTokens fromPack(ThemePack pack, Brightness brightness) {
    final tokens = pack.tokens.forBrightness(brightness);
    final accent = tokens.accent ?? AppColors.primary;
    return fromTokens(
      packId: pack.id,
      tokens: tokens,
      language: pack.language,
      graphics: pack.graphics,
      shell: pack.shell,
      components: pack.components,
      bridges: pack.bridges,
      parts: pack.parts,
      ui: pack.ui,
      accent: accent,
    );
  }

  static AsemanTokens fromTokens({
    required String packId,
    required ThemeTokens tokens,
    required ThemeGraphics graphics,
    required ShellLayoutSpec shell,
    required Map<String, ComponentStyle> components,
    required ThemeBridges bridges,
    DesignLanguage language = const DesignLanguage(),
    ThemePartColors parts = const ThemePartColors(),
    ThemeUiSpec ui = const ThemeUiSpec(),
    Color? accent,
  }) {
    final brand = accent ?? tokens.accent ?? AppColors.primary;
    final unified = parts.unified || parts.overrides.isEmpty;
    return AsemanTokens(
      packId: packId,
      cardAlpha: tokens.cardAlpha,
      overlayAlpha: tokens.overlayAlpha,
      blurSigma: tokens.blurSigma,
      barrier: tokens.barrier ?? AppSurfaces.barrier,
      radiusCard: tokens.radiusCard,
      radiusInner: tokens.radiusInner,
      radiusControl: tokens.radiusControl,
      radiusFab: tokens.radiusFab,
      radiusFabSmall: tokens.radiusFabSmall,
      radiusFabLarge: tokens.radiusFabLarge,
      spacingScale: tokens.spacingScale,
      density: tokens.density,
      motionScale: tokens.motionScale,
      reduceMotion: tokens.reduceMotion,
      // Unified packs fold decorative secondary into the brand accent.
      cyan: unified
          ? brand
          : (tokens.secondaryAccent ?? brand),
      success: tokens.success ?? AppColors.success,
      warning: tokens.warning ?? AppColors.warning,
      danger: tokens.danger ?? AppColors.danger,
      atmosphere: graphics.atmosphere,
      haloStyle: graphics.haloStyle,
      iconTreatment: graphics.iconTreatment,
      language: language,
      shell: shell,
      components: components,
      bridges: bridges,
      fabMistAlpha: tokens.fabMistAlpha,
      navHeight: tokens.navHeight,
      accent: brand,
      parts: parts,
      ui: ui,
    );
  }

  ComponentStyle? component(String slot) => components[slot];

  ShapeBorder get overlayShape => control('card').border();

  ShapeBorder get sheetShape {
    final sheet = control('sheet');
    if (sheet.shape == ShapeKind.sharp) {
      return const RoundedRectangleBorder(borderRadius: BorderRadius.zero);
    }
    if (sheet.shape == ShapeKind.cut) {
      return BeveledRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(sheet.radius.clamp(0, 16)),
        ),
      );
    }
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(sheet.radius)),
    );
  }

  @override
  AsemanTokens copyWith({
    String? packId,
    double? cardAlpha,
    double? overlayAlpha,
    double? blurSigma,
    Color? barrier,
    double? radiusCard,
    double? radiusInner,
    double? radiusControl,
    double? radiusFab,
    double? radiusFabSmall,
    double? radiusFabLarge,
    double? spacingScale,
    double? density,
    double? motionScale,
    bool? reduceMotion,
    Color? cyan,
    Color? success,
    Color? warning,
    Color? danger,
    String? atmosphere,
    String? haloStyle,
    String? iconTreatment,
    DesignLanguage? language,
    ShellLayoutSpec? shell,
    Map<String, ComponentStyle>? components,
    ThemeBridges? bridges,
    double? fabMistAlpha,
    double? navHeight,
    Color? accent,
    ThemePartColors? parts,
    ThemeUiSpec? ui,
  }) =>
      AsemanTokens(
        packId: packId ?? this.packId,
        cardAlpha: cardAlpha ?? this.cardAlpha,
        overlayAlpha: overlayAlpha ?? this.overlayAlpha,
        blurSigma: blurSigma ?? this.blurSigma,
        barrier: barrier ?? this.barrier,
        radiusCard: radiusCard ?? this.radiusCard,
        radiusInner: radiusInner ?? this.radiusInner,
        radiusControl: radiusControl ?? this.radiusControl,
        radiusFab: radiusFab ?? this.radiusFab,
        radiusFabSmall: radiusFabSmall ?? this.radiusFabSmall,
        radiusFabLarge: radiusFabLarge ?? this.radiusFabLarge,
        spacingScale: spacingScale ?? this.spacingScale,
        density: density ?? this.density,
        motionScale: motionScale ?? this.motionScale,
        reduceMotion: reduceMotion ?? this.reduceMotion,
        cyan: cyan ?? this.cyan,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        atmosphere: atmosphere ?? this.atmosphere,
        haloStyle: haloStyle ?? this.haloStyle,
        iconTreatment: iconTreatment ?? this.iconTreatment,
        language: language ?? this.language,
        shell: shell ?? this.shell,
        components: components ?? this.components,
        bridges: bridges ?? this.bridges,
        fabMistAlpha: fabMistAlpha ?? this.fabMistAlpha,
        navHeight: navHeight ?? this.navHeight,
        accent: accent ?? this.accent,
        parts: parts ?? this.parts,
        ui: ui ?? this.ui,
      );

  @override
  AsemanTokens lerp(ThemeExtension<AsemanTokens>? other, double t) {
    if (other is! AsemanTokens) return this;
    if (t < 0.5) return this;
    return other;
  }
}
