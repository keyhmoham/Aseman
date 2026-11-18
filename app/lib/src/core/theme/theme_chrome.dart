import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_shape.dart';
import 'app_surfaces.dart';
import 'aseman_tokens.dart';
import 'control_look.dart';
import 'default_theme_packs.dart';
import 'design_language.dart';

/// Single entry for chrome that must follow the active theme pack.
///
/// Prefer this over raw [AppShape] / [AppSurfaces] constants in widgets so
/// installed languages reshape every surface without per-call omissions.
extension AsemanThemeX on BuildContext {
  AsemanTokens get asemanTokens => AsemanTokens.of(this);

  AsemanTokens? get maybeAsemanTokens => AsemanTokens.maybeOf(this);

  ControlRecipe control(String slot) => asemanTokens.control(slot);

  ControlRecipe get buttonRecipe => control('button');
  ControlRecipe get chipRecipe => control('chip');
  ControlRecipe get navPillRecipe => control('nav_pill');
  ControlRecipe get panelHeaderRecipe => control('panel_header');
  ControlRecipe get fabRecipe => control('fab');

  double get radiusCard =>
      maybeAsemanTokens?.control('card').radius ??
      maybeAsemanTokens?.radiusCard ??
      AppShape.card;

  double get radiusInner =>
      maybeAsemanTokens?.control('panel_header').radius ??
      maybeAsemanTokens?.radiusInner ??
      AppShape.inner;

  double get radiusControl =>
      maybeAsemanTokens?.control('input').radius ??
      maybeAsemanTokens?.radiusControl ??
      AppShape.control;

  double get radiusFab =>
      maybeAsemanTokens?.control('fab').radius ??
      maybeAsemanTokens?.radiusFab ??
      AppShape.fab;

  double get navHeight =>
      maybeAsemanTokens?.navHeight ?? 64;

  BorderRadius get cardBorderRadius =>
      maybeAsemanTokens?.control('card').borderRadius ??
      BorderRadius.circular(radiusCard);

  BorderRadius get navPillBorderRadius => navPillRecipe.borderRadius;

  BorderRadius get sheetBorderRadius {
    final sheet = maybeAsemanTokens?.control('sheet');
    if (sheet != null) {
      return BorderRadius.vertical(top: Radius.circular(sheet.radius));
    }
    return BorderRadius.vertical(top: Radius.circular(radiusCard));
  }

  Color get themeCyan =>
      maybeAsemanTokens?.cyan ?? const Color(0xFF58D7FF);

  Color get themeSuccess =>
      maybeAsemanTokens?.success ?? const Color(0xFF43D39E);

  Color get themeWarning =>
      maybeAsemanTokens?.warning ?? const Color(0xFFFFB648);

  Color get themeDanger =>
      maybeAsemanTokens?.danger ?? const Color(0xFFFF6B79);

  Color get themePrimary => Theme.of(this).colorScheme.primary;

  /// Corner radius for avatar faces **and** their halo rings.
  ///
  /// Prefers the language `avatar` recipe, then pack `radiusControl` / chip
  /// shape, so Theme Studio radius edits reshape the face — not only the ring.
  BorderRadius avatarBorderRadius(double size) {
    final tokens = maybeAsemanTokens;
    final half = size / 2;
    if (half <= 0) return BorderRadius.zero;

    final avatar = tokens?.control('avatar');
    final chip = tokens?.control('chip');
    final halo = tokens?.haloStyle ?? 'ring';
    final control = tokens?.radiusControl;

    ShapeKind? shape = avatar?.shape;
    double? recipeR = avatar?.radius;

    final forceSharp = halo == 'square' ||
        tokens?.iconTreatment == 'sharp' ||
        chip?.shape == ShapeKind.sharp ||
        chip?.shape == ShapeKind.cut;

    // Default avatar recipe is stadium/999 (= circle). Inherit sharper language
    // radii so Fluent / Neo-brutal / custom control radius actually apply.
    final avatarIsDefaultCircle = shape == null ||
        shape == ShapeKind.stadium ||
        (recipeR != null && recipeR >= 999);

    if (forceSharp) {
      shape = ShapeKind.sharp;
      recipeR = control ?? chip?.radius ?? 0;
    } else if (avatarIsDefaultCircle) {
      if (chip?.shape == ShapeKind.rounded ||
          chip?.shape == ShapeKind.squircle) {
        shape = chip!.shape;
        recipeR = chip.radius <= 0 ? (control ?? half) : chip.radius;
      } else if (control != null) {
        shape = ShapeKind.rounded;
        recipeR = control;
      } else {
        shape = ShapeKind.stadium;
        recipeR = half;
      }
    }

    final resolved = (recipeR ?? control ?? half).clamp(0, half).toDouble();
    if (shape == ShapeKind.stadium || resolved >= half * .92) {
      return BorderRadius.circular(half);
    }
    return BorderRadius.circular(resolved);
  }

  bool get avatarsAreCircular {
    final r = avatarBorderRadius(40);
    return r.topLeft.x >= 19.5;
  }

  List<BoxShadow> themeShadow({Color? accent}) {
    final scheme = Theme.of(this).colorScheme;
    final ink = accent ?? scheme.primary;
    return maybeAsemanTokens?.language.shadow
            .resolve(scheme, accent: ink) ??
        [
          BoxShadow(
            color: Colors.black.withValues(
                alpha: scheme.brightness == Brightness.dark ? .35 : .10),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: ink.withValues(
                alpha: scheme.brightness == Brightness.dark ? .28 : .12),
            blurRadius: 18,
            spreadRadius: -2,
            offset: const Offset(0, 3),
          ),
        ];
  }

  /// Compact icon-button chrome for floating bars / dense toolbars.
  ButtonStyle barIconButtonStyle({
    double min = 32,
    double iconSize = 18,
    EdgeInsetsGeometry padding = const EdgeInsets.all(4),
  }) {
    final scheme = Theme.of(this).colorScheme;
    final shape = buttonRecipe.border(sideColor: scheme.outlineVariant);
    return IconButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: Size(min, min),
      padding: padding,
      iconSize: iconSize,
      shape: shape,
      highlightColor: scheme.primary.withValues(
          alpha: maybeAsemanTokens?.language.interaction.hoverAlpha ?? .08),
    );
  }

  /// Tonal icon well used by section headers, tiles, and badges.
  Decoration iconWellDecoration({
    Color? accent,
    double size = 46,
  }) {
    final scheme = Theme.of(this).colorScheme;
    final a = accent ?? scheme.primary;
    final chip = chipRecipe;
    final r = chip.shape == ShapeKind.stadium
        ? size / 2
        : (chip.radius <= 0
            ? size * .34
            : chip.radius.clamp(0, size / 2).toDouble());
    final well = chip.copyWith(
      radius: r,
      borderWidth: chip.borderWidth > 0
          ? chip.borderWidth
          : (chip.fill == FillKind.outline ? 1 : 0),
    );
    final side = a.withValues(
        alpha: well.borderWidth > 0 ? well.borderAlpha : 0.16);
    return ShapeDecoration(
      color: a.withValues(
          alpha: chip.fill == FillKind.outline ? 0.04 : 0.12),
      shape: ThemeChrome.outlinedBorder(
        well,
        sideColor: well.borderWidth > 0 ? side : null,
        borderWidth: well.borderWidth,
      ),
    );
  }

  /// Meta / status chip fill following the pack chip recipe.
  Decoration metaChipDecoration({Color? accent}) {
    final scheme = Theme.of(this).colorScheme;
    final color = accent ?? scheme.onSurfaceVariant;
    final chip = chipRecipe;
    final side = chip.borderWidth > 0
        ? color.withValues(alpha: chip.borderAlpha)
        : color.withValues(alpha: chip.fill == FillKind.outline ? .55 : 0);
    final width = chip.borderWidth > 0
        ? chip.borderWidth
        : (chip.fill == FillKind.outline ? 1.0 : 0.0);
    final shape = ThemeChrome.outlinedBorder(
      chip,
      sideColor: side,
      borderWidth: width,
    );
    final fill = switch (chip.fill) {
      FillKind.outline || FillKind.text => Colors.transparent,
      FillKind.solid => color.withValues(alpha: .16),
      _ => color.withValues(alpha: .1),
    };
    return ShapeDecoration(color: fill, shape: shape);
  }

  /// Outlined border for a control slot (cut / stadium / sharp / rounded).
  OutlinedBorder controlShape(
    String slot, {
    Color? sideColor,
    double? borderWidth,
  }) =>
      ThemeChrome.outlinedBorder(
        control(slot),
        sideColor: sideColor,
        borderWidth: borderWidth,
      );
}

/// Resolves radii / surfaces from tokens when a [BuildContext] is available.
abstract final class ThemeChrome {
  /// Resolves a full graphical [ControlLook] for [slot] under the active pack.
  static ControlLook look(
    BuildContext context,
    String slot, {
    Color? accent,
    bool selected = false,
    bool hovered = false,
    bool pressed = false,
    bool focused = false,
    bool disabled = false,
    TextStyle? baseText,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    var recipe = tokens?.control(slot) ??
        AsemanTokens.maybeOf(context)?.language.recipeFor(slot) ??
        const ControlRecipe();
    final interaction = tokens?.language.interaction;
    // Inherit global interaction defaults when the slot left motion identity.
    if (recipe.motion.isIdentity && interaction != null) {
      recipe = recipe.copyWith(motion: interaction.asMotion);
    }
    if (recipe.ink == InkKind.ripple &&
        interaction != null &&
        interaction.ink != InkKind.ripple) {
      recipe = recipe.copyWith(ink: interaction.ink);
    }
    final state = recipe.states.forFlags(
      hovered: hovered,
      pressed: pressed,
      focused: focused,
      selected: selected,
      disabled: disabled,
    );
    recipe = recipe.withState(state);
    final accentColor = accent ??
        accentColorFor(context, recipe.accentRole, fallback: scheme.primary);
    final fill = _fillForRecipe(
      context,
      recipe,
      accent: accentColor,
      selected: selected,
      slot: slot,
      // Cards / sheets / bubbles stay neutral — accent is for ink & selection.
      neutral: _isSurfaceSlot(slot),
    );
    final sideColor = selected
        ? accentColor
        : (recipe.fill == FillKind.outline
            ? accentColor
            : AppSurfaces.cardBorder(scheme));
    final shape = outlinedBorder(
      recipe,
      sideColor: recipe.borderWidth > 0 || recipe.fill == FillKind.outline
          ? sideColor
          : null,
      borderWidth: recipe.borderWidth > 0
          ? recipe.borderWidth
          : (recipe.fill == FillKind.outline ? 1.0 : 0.0),
    );
    final shadows = recipe.elevation > 0
        ? tokens?.language.shadow.resolve(scheme, accent: accentColor)
        : null;
    final text = recipe.typography.isEmpty
        ? null
        : recipe.typography.apply(
            baseText ?? Theme.of(context).textTheme.labelLarge ?? const TextStyle(),
          );
    // Prefer opaque M3 container fills over accent gradient washes (vibe
    // bubble). Packs may still opt into an explicit [ControlRecipe.gradient].
    final g = recipe.fill == FillKind.gradient && recipe.gradient != null
        ? recipe.gradient!.toGradient()
        : null;
    final effects = recipe.effects.copyWith(
      focusRing: focused && recipe.effects.focusRing <= 0
          ? (interaction?.focusRing ?? 0)
          : recipe.effects.focusRing,
      grain: recipe.effects.grain > 0
          ? recipe.effects.grain
          : (tokens != null ? 0 : 0),
    );
    return ControlLook(
      slot: slot,
      recipe: recipe,
      shape: shape,
      fill: fill,
      padding: EdgeInsets.symmetric(
        horizontal: recipe.paddingH,
        vertical: recipe.paddingV,
      ),
      ink: recipe.ink,
      motion: recipe.motion,
      effects: effects,
      gradient: g,
      shadows: shadows,
      textStyle: text,
      iconSize: recipe.iconography.size ?? tokens?.language.iconSize,
      labelsUppercase: recipe.labelsUppercase || recipe.typography.allCaps,
    );
  }

  static Color accentColorFor(
    BuildContext context,
    AccentRole role, {
    Color? fallback,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    return switch (role) {
      AccentRole.primary => scheme.primary,
      AccentRole.secondary => tokens?.cyan ?? scheme.secondary,
      AccentRole.surface => scheme.surface,
      AccentRole.onSurface => scheme.onSurface,
      AccentRole.success => tokens?.success ?? scheme.tertiary,
      AccentRole.warning => tokens?.warning ?? scheme.tertiary,
      AccentRole.danger => tokens?.danger ?? scheme.error,
      AccentRole.custom => fallback ?? scheme.primary,
    };
  }

  static bool _isSurfaceSlot(String slot) => switch (slot) {
        'card' ||
        'sheet' ||
        'bottom_sheet' ||
        'dialog' ||
        'menu' ||
        'popup' ||
        'panel_header' ||
        'panelHeader' ||
        'list_tile' ||
        'listTile' ||
        'tile' ||
        'chat_bubble' ||
        'chatBubble' ||
        'tooltip' =>
          true,
        _ => false,
      };

  static Color _fillForRecipe(
    BuildContext context,
    ControlRecipe recipe, {
    required Color accent,
    bool selected = false,
    bool neutral = false,
    String slot = '',
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    if (selected) {
      return Color.alphaBlend(
        accent.withValues(alpha: .10),
        AppSurfaces.card(scheme, tokens: tokens),
      );
    }
    // Surface family: never paint the whole control in the accent colour.
    if (neutral) {
      return switch (recipe.fill) {
        FillKind.solid || FillKind.tonal => scheme.surface,
        FillKind.glass || FillKind.gradient =>
          AppSurfaces.card(scheme, tokens: tokens),
        FillKind.outline || FillKind.text => Colors.transparent,
      };
    }
    final isFab = slot == 'fab';
    // M3 Expressive: filled button = primary; FAB / soft container =
    // primary-container; tonal = secondary-container (opaque, not a wash).
    return switch (recipe.fill) {
      FillKind.solid =>
        isFab ? scheme.primaryContainer : scheme.primary,
      FillKind.tonal => scheme.secondaryContainer,
      FillKind.outline || FillKind.text => Colors.transparent,
      FillKind.glass => AppSurfaces.overlay(scheme, tokens: tokens),
      FillKind.gradient =>
        isFab ? scheme.primaryContainer : scheme.primary,
    };
  }

  /// Builds the pack's true [OutlinedBorder] (including cut / stadium).
  static OutlinedBorder outlinedBorder(
    ControlRecipe recipe, {
    Color? sideColor,
    double? borderWidth,
  }) {
    final width = borderWidth ?? recipe.borderWidth;
    final side = width > 0 && sideColor != null
        ? BorderSide(
            color: sideColor.withValues(alpha: recipe.borderAlpha),
            width: width,
          )
        : (width > 0 && sideColor == null
            ? BorderSide(
                color: Colors.black.withValues(alpha: recipe.borderAlpha),
                width: width,
              )
            : BorderSide.none);
    return switch (recipe.shape) {
      ShapeKind.stadium => StadiumBorder(side: side),
      ShapeKind.sharp => RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: side,
        ),
      ShapeKind.cut => BeveledRectangleBorder(
          borderRadius: BorderRadius.circular(recipe.radius.clamp(0, 16)),
          side: side,
        ),
      ShapeKind.squircle => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
              recipe.radius <= 0 ? 28 : recipe.radius * 1.35),
          side: side,
        ),
      ShapeKind.rounded => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(recipe.radius),
          side: side,
        ),
    };
  }

  static OutlinedBorder shapeOf(
    BuildContext context, {
    String slot = 'card',
    Color? sideColor,
    double? borderWidth,
  }) {
    final recipe = AsemanTokens.maybeOf(context)?.control(slot) ??
        const ControlRecipe();
    return outlinedBorder(
      recipe,
      sideColor: sideColor,
      borderWidth: borderWidth,
    );
  }

  static InteractiveInkFeatureFactory? splashFactory(
    BuildContext context, {
    InkKind? ink,
  }) {
    final kind = ink ??
        AsemanTokens.maybeOf(context)?.language.interaction.ink ??
        InkKind.ripple;
    return switch (kind) {
      InkKind.ripple => null,
      InkKind.highlight || InkKind.none => NoSplash.splashFactory,
    };
  }

  static Color pressHighlight(
    BuildContext context, {
    Color? accent,
    InkKind? ink,
  }) {
    final tokens = AsemanTokens.maybeOf(context);
    final kind = ink ?? tokens?.language.interaction.ink ?? InkKind.ripple;
    if (kind == InkKind.none) return Colors.transparent;
    final color = accent ?? Theme.of(context).colorScheme.primary;
    final alpha = kind == InkKind.highlight
        ? (tokens?.language.interaction.hoverAlpha ?? .12)
        : (tokens?.language.interaction.hoverAlpha ?? .08);
    return color.withValues(alpha: alpha);
  }

  static Color pressSplash(
    BuildContext context, {
    Color? accent,
    InkKind? ink,
  }) {
    final kind = ink ??
        AsemanTokens.maybeOf(context)?.language.interaction.ink ??
        InkKind.ripple;
    if (kind != InkKind.ripple) return Colors.transparent;
    final color = accent ?? Theme.of(context).colorScheme.primary;
    return color.withValues(alpha: .12);
  }

  /// Radial sky / mist washes. Flat packs (Paper) stay on solid surfaces.
  ///
  /// Missing tokens keep the Sky default so unthemed previews do not go blank.
  static bool paintsAtmosphere(BuildContext context) {
    final atmosphere = AsemanTokens.maybeOf(context)?.atmosphere ?? 'sky';
    return atmosphere == 'sky' || atmosphere == 'mist';
  }

  /// The built-in Paper pack: print-like Material 3, no sky glow.
  static bool isPaper(BuildContext context) =>
      AsemanTokens.maybeOf(context)?.packId == DefaultThemePacks.paperId;

  /// Selected navigation captions. Paper matches the expressive rail (w500).
  static FontWeight selectedNavWeight(
    BuildContext context, {
    FontWeight fallback = FontWeight.w700,
  }) =>
      isPaper(context) ? FontWeight.w500 : fallback;

  /// Whether frost/blur should run for card-like surfaces under this pack.
  static bool wantsGlassBlur(BuildContext context, {String slot = 'card'}) {
    final tokens = AsemanTokens.maybeOf(context);
    if (tokens == null) return true;
    if (tokens.blurSigma <= 0) return false;
    final fill = tokens.control(slot).fill;
    return fill == FillKind.glass || fill == FillKind.gradient;
  }

  static double cardRadius(BuildContext? context,
          [double fallback = AppShape.card]) =>
      context?.radiusCard ?? fallback;

  static double innerRadius(BuildContext? context,
          [double fallback = AppShape.inner]) =>
      context?.radiusInner ?? fallback;

  static double controlRadius(BuildContext? context,
          [double fallback = AppShape.control]) =>
      context?.radiusControl ?? fallback;

  static Color card(BuildContext context) {
    final tokens = AsemanTokens.maybeOf(context);
    return AppSurfaces.card(Theme.of(context).colorScheme, tokens: tokens);
  }

  static Color overlay(BuildContext context) {
    final tokens = AsemanTokens.maybeOf(context);
    return AppSurfaces.overlay(Theme.of(context).colorScheme, tokens: tokens);
  }

  static Color cardBorder(BuildContext context) =>
      AppSurfaces.cardBorder(Theme.of(context).colorScheme);

  /// Shared shape / padding / type for pack buttons (no fill — callers set
  /// M3 Expressive color roles so [FilledButton.tonal] can keep
  /// secondary-container).
  static ButtonStyle buttonStyle(
    ThemeData base, {
    required AsemanTokens tokens,
    Color? sideColor,
    bool forceOutline = false,
  }) {
    final scheme = base.colorScheme;
    final label = base.textTheme.labelLarge ?? const TextStyle();
    final button = tokens.control('button');
    final outlined = forceOutline || button.fill == FillKind.outline;
    final shape = button.border(
      sideColor: outlined || button.borderWidth > 0
          ? (sideColor ?? scheme.outline)
          : null,
    );
    return ButtonStyle(
      shape: WidgetStatePropertyAll(shape),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(
          horizontal: button.paddingH, vertical: button.paddingV)),
      minimumSize: WidgetStatePropertyAll(
          Size(0, button.minHeight ?? tokens.language.controlHeight)),
      elevation: WidgetStatePropertyAll(button.elevation),
      textStyle: WidgetStatePropertyAll(
          label.copyWith(fontWeight: FontWeight.w700, fontSize: 14)),
      splashFactory: switch (tokens.language.interaction.ink) {
        InkKind.ripple => null,
        InkKind.highlight || InkKind.none => NoSplash.splashFactory,
      },
    );
  }

  /// M3 Expressive filled: primary / on-primary (solid, no mist or rim).
  ///
  /// Colors stay off the shared [FilledButtonTheme] so [FilledButton.tonal]
  /// can still resolve to secondary-container / on-secondary-container.
  static ButtonStyle filledButtonStyle(
    ThemeData base, {
    required AsemanTokens tokens,
  }) =>
      buttonStyle(base, tokens: tokens);

  /// M3 Expressive tonal: secondary-container / on-secondary-container.
  static ButtonStyle tonalButtonStyle(
    ThemeData base, {
    required AsemanTokens tokens,
  }) {
    final scheme = base.colorScheme;
    return buttonStyle(base, tokens: tokens).copyWith(
      backgroundColor: WidgetStatePropertyAll(scheme.secondaryContainer),
      foregroundColor: WidgetStatePropertyAll(scheme.onSecondaryContainer),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        final ink = scheme.onSecondaryContainer;
        if (states.contains(WidgetState.pressed)) {
          return ink.withValues(alpha: .12);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return ink.withValues(
              alpha: tokens.language.interaction.hoverAlpha);
        }
        return null;
      }),
    );
  }

  /// M3 Expressive elevated: surface-container-low / primary.
  static ButtonStyle elevatedButtonStyle(
    ThemeData base, {
    required AsemanTokens tokens,
  }) {
    final scheme = base.colorScheme;
    final button = tokens.control('button');
    return buttonStyle(base, tokens: tokens).copyWith(
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
      foregroundColor: WidgetStatePropertyAll(scheme.primary),
      elevation: WidgetStatePropertyAll(
          button.elevation > 0 ? button.elevation : 1),
      shadowColor: WidgetStatePropertyAll(scheme.shadow),
    );
  }

  /// M3 Expressive outlined: outline / on-surface-variant.
  static ButtonStyle outlinedButtonStyle(
    ThemeData base, {
    required AsemanTokens tokens,
  }) {
    final scheme = base.colorScheme;
    final button = tokens.control('button');
    return buttonStyle(
      base,
      tokens: tokens,
      sideColor: scheme.outline,
      forceOutline: true,
    ).copyWith(
      foregroundColor: WidgetStatePropertyAll(scheme.onSurfaceVariant),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      side: WidgetStatePropertyAll(BorderSide(
        color: scheme.outline,
        width: button.borderWidth > 0 ? button.borderWidth : 1,
      )),
    );
  }

  static ButtonStyle iconButtonStyle(
    ThemeData base, {
    required AsemanTokens tokens,
  }) {
    final scheme = base.colorScheme;
    final button = tokens.control('button');
    final shape = button.border(sideColor: scheme.outlineVariant);
    // Force shape through styleFrom so Material 3's default circular
    // IconButton geometry cannot win over the pack recipe.
    return IconButton.styleFrom(
      shape: shape,
      highlightColor: scheme.primary
          .withValues(alpha: tokens.language.interaction.hoverAlpha),
    ).copyWith(
      splashFactory: tokens.language.interaction.ink == InkKind.ripple
          ? null
          : NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return scheme.primary.withValues(alpha: .12);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return scheme.primary
              .withValues(alpha: tokens.language.interaction.hoverAlpha);
        }
        return null;
      }),
    );
  }

  /// Corner radii for SoftCard / QuietList / card chrome.
  ///
  /// Always follows the pack `card` recipe (shape + radius), so literals like
  /// `16` / `22` / `AppShape.card - 2` cannot leave a card on the old Sky
  /// corners. Without tokens, [requested] still resolves through [AppShape].
  static BorderRadius softCardCorners(
    BuildContext context, [
    double requested = AppShape.inner,
  ]) {
    final tokens = AsemanTokens.maybeOf(context);
    final card = tokens?.control('card');
    if (card == null) {
      return BorderRadius.circular(AppShape.resolve(context, requested));
    }
    return card.borderRadius;
  }

  /// Unified card / panel fill from the pack (shape-agnostic color).
  static Color cardFillColor(
    BuildContext context, {
    Color? accent,
    bool selected = false,
    bool wash = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final card = tokens?.control('card');
    final accentColor = accent ?? scheme.primary;
    final cardFill = AppSurfaces.card(scheme, tokens: tokens);
    final fillKind = card?.fill ?? FillKind.solid;
    final paper = tokens?.packId == DefaultThemePacks.paperId;
    if (paper &&
        (fillKind == FillKind.solid || fillKind == FillKind.tonal)) {
      if (selected) return scheme.secondaryContainer;
      // Whisper of accent over a neutral surface — the full container color
      // is far too loud for in-page cards (both light and dark).
      if (wash) {
        return Color.alphaBlend(
          scheme.primaryContainer.withValues(alpha: .22),
          scheme.surfaceContainerLow,
        );
      }
      return scheme.surfaceContainerHigh;
    }
    if (selected) {
      return Color.alphaBlend(accentColor.withValues(alpha: .10), cardFill);
    }
    if (wash) {
      return Color.alphaBlend(accentColor.withValues(alpha: .05), cardFill);
    }
    // Prefer opaque pack surface for in-page cards; glass stays for overlays.
    return switch (fillKind) {
      FillKind.solid || FillKind.tonal => scheme.surface,
      FillKind.glass || FillKind.gradient => cardFill,
      FillKind.outline || FillKind.text => Colors.transparent,
    };
  }

  /// True [OutlinedBorder] for SoftCard / GlassSurface / QuietList.
  static OutlinedBorder cardShape(
    BuildContext context, {
    Color? accent,
    bool selected = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final card = tokens?.control('card') ?? const ControlRecipe();
    final accentColor = accent ?? scheme.primary;
    final borderW = selected
        ? math.max(card.borderWidth, 1.4)
        : card.borderWidth;
    final sideColor = selected
        ? accentColor.withValues(alpha: .55)
        : AppSurfaces.cardBorder(scheme);
    return outlinedBorder(
      card,
      sideColor: borderW > 0 ? sideColor : null,
      borderWidth: borderW,
    );
  }

  /// Unified card / panel fill, border, and elevation from the pack.
  ///
  /// Prefer [cardShape] + Material for cut / stadium packs; this decoration
  /// still works for radius-based [BoxDecoration] call sites.
  static BoxDecoration cardDecoration(
    BuildContext context, {
    Color? accent,
    bool selected = false,
    bool elevated = false,
    bool wash = false,
    double? radiusOverride,
    BorderRadius? borderRadius,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final card = tokens?.control('card');
    final accentColor = accent ?? scheme.primary;
    final fill = cardFillColor(
      context,
      accent: accent,
      selected: selected,
      wash: wash,
    );
    final corners = borderRadius ??
        softCardCorners(context, radiusOverride ?? AppShape.inner);
    final borderW = selected
        ? math.max(card?.borderWidth ?? 0, 1.4)
        : (card?.borderWidth ?? 0);
    final borderColor = selected
        ? accentColor.withValues(alpha: .55)
        : AppSurfaces.cardBorder(scheme).withValues(
            alpha: card != null && card.borderWidth > 0
                ? card.borderAlpha
                : 1);
    final wantShadow =
        elevated || selected || (card != null && card.elevation > 0);
    final shadows = !wantShadow
        ? null
        : (tokens?.language.shadow.resolve(scheme, accent: accentColor) ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: elevated ? .08 : .05),
                blurRadius: elevated ? 16 : 10,
                offset: const Offset(0, 4),
              ),
            ]);
    return BoxDecoration(
      color: fill,
      borderRadius: corners,
      border: borderW > 0
          ? Border.all(color: borderColor, width: borderW)
          : null,
      boxShadow: shadows,
    );
  }

  /// Search / command / composer field chrome from the `input` recipe.
  static InputDecoration searchDecoration(
    BuildContext context, {
    String? hintText,
    Widget? prefixIcon,
    Widget? suffixIcon,
    bool dense = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final input = tokens?.control('input');
    final corners = input?.borderRadius ?? BorderRadius.circular(
      input?.shape == ShapeKind.stadium ? 999 : (tokens?.radiusControl ?? 16),
    );
    final paper = tokens?.packId == DefaultThemePacks.paperId;
    final fill = paper
        ? scheme.surfaceContainerHighest
        : switch (input?.fill) {
      FillKind.solid => scheme.surface,
      FillKind.glass || FillKind.gradient =>
        AppSurfaces.overlay(scheme, tokens: tokens),
      FillKind.outline || FillKind.text => Colors.transparent,
      _ => scheme.surfaceContainerHighest.withValues(
          alpha: tokens?.cardAlpha ?? .42,
        ),
    };
    final side = AppSurfaces.cardBorder(scheme);
    final width = input?.borderWidth ?? 0;
    final enabledW = width > 0 ? width : 0.0;
    final focusedW = width > 0 ? math.max(width, 1.4) : 1.4;
    InputBorder outline(Color c, double w) {
      if (input?.shape == ShapeKind.sharp) {
        return OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: w <= 0 ? BorderSide.none : BorderSide(color: c, width: w),
        );
      }
      if (input?.shape == ShapeKind.cut) {
        return OutlineInputBorder(
          borderRadius: BorderRadius.circular(
              (input?.radius ?? 8).clamp(0, 16)),
          borderSide: w <= 0 ? BorderSide.none : BorderSide(color: c, width: w),
        );
      }
      return OutlineInputBorder(
        borderRadius: corners,
        borderSide: w <= 0 ? BorderSide.none : BorderSide(color: c, width: w),
      );
    }

    return InputDecoration(
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      hintText: hintText,
      filled: input?.fill != FillKind.outline && input?.fill != FillKind.text,
      fillColor: fill,
      contentPadding: EdgeInsets.symmetric(
        horizontal: input?.paddingH ?? 8,
        vertical: dense ? 10 : (input?.paddingV ?? 14),
      ),
      border: outline(side, enabledW),
      enabledBorder: outline(
          side.withValues(alpha: input?.borderAlpha ?? 1), enabledW),
      focusedBorder: outline(scheme.primary, focusedW),
      disabledBorder: outline(side, enabledW),
    );
  }

  /// Shell for chat / command composers (Material fill + elevation + radius).
  static ({
    Color color,
    double elevation,
    BorderRadius radius,
    EdgeInsets padding,
  }) inputShell(
    BuildContext context, {
    bool elevated = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final input = tokens?.control('input');
    final card = tokens?.control('card');
    final color = switch (input?.fill) {
      FillKind.solid => scheme.surface,
      FillKind.glass => AppSurfaces.overlay(scheme, tokens: tokens),
      _ => scheme.surfaceContainerHigh,
    };
    final radius = input?.borderRadius ??
        card?.borderRadius ??
        BorderRadius.circular(tokens?.radiusCard ?? AppShape.card);
    final elevation = elevated
        ? math.max(input?.elevation ?? 0, 3).toDouble()
        : (input?.elevation ?? 0);
    final pad = EdgeInsets.all(
      ((input?.paddingV ?? 6) + (input?.paddingH ?? 6)) / 2,
    );
    return (
      color: color,
      elevation: elevation,
      radius: radius,
      padding: pad,
    );
  }

  /// Message bubble decoration driven by `chat_bubble` (+ optional tail).
  static BoxDecoration chatBubble(
    BuildContext context, {
    required bool mine,
    bool continued = false,
    bool agent = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final bubble = tokens?.control('chat_bubble');
    final BorderRadius corners;
    if (bubble == null) {
      const r = Radius.circular(20);
      const tip = Radius.circular(6);
      corners = BorderRadius.only(
        topLeft: !mine && !continued ? tip : r,
        topRight: mine && !continued ? tip : r,
        bottomLeft: r,
        bottomRight: r,
      );
    } else if (bubble.shape == ShapeKind.sharp) {
      corners = BorderRadius.zero;
    } else if (bubble.shape == ShapeKind.stadium) {
      corners = BorderRadius.circular(999);
    } else {
      final r = bubble.radius;
      final tip = math.max(4.0, r * .3);
      final Radius big = Radius.circular(r);
      final Radius tail = Radius.circular(tip);
      corners = BorderRadius.only(
        topLeft: !mine && !continued ? tail : big,
        topRight: mine && !continued ? tail : big,
        bottomLeft: big,
        bottomRight: big,
      );
    }
    final Color fill;
    final paper = tokens?.packId == DefaultThemePacks.paperId;
    if (paper) {
      // Two steps of the same accent: saturated container for you, a quieter
      // surface step for everyone else.
      fill = mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    } else if (mine) {
      fill = scheme.primaryContainer;
    } else if (agent) {
      fill = scheme.primary.withValues(alpha: .10);
    } else if (bubble?.fill == FillKind.solid) {
      fill = scheme.surface;
    } else {
      fill = scheme.surfaceContainerHigh;
    }
    final borderW = bubble?.borderWidth ?? 0;
    return BoxDecoration(
      color: fill,
      borderRadius: corners,
      border: borderW > 0
          ? Border.all(
              color: (mine || agent ? scheme.primary : scheme.outlineVariant)
                  .withValues(alpha: bubble?.borderAlpha ?? .3),
              width: borderW,
            )
          : (agent
              ? Border.all(color: scheme.primary.withValues(alpha: .3))
              : null),
      boxShadow: (bubble?.elevation ?? 0) > 0
          ? tokens?.language.shadow.resolve(scheme)
          : null,
    );
  }

  static EdgeInsets chatBubblePadding(BuildContext context) {
    final bubble = AsemanTokens.maybeOf(context)?.control('chat_bubble');
    return EdgeInsets.fromLTRB(
      bubble?.paddingH ?? 14,
      bubble?.paddingV ?? 10,
      bubble?.paddingH ?? 14,
      (bubble?.paddingV ?? 10) - 2,
    );
  }

  static SwitchThemeData switchTheme(
    ColorScheme scheme, {
    required AsemanTokens tokens,
  }) {
    final toggle = tokens.control('toggle');
    final ink = toggle.ink != InkKind.ripple
        ? toggle.ink
        : tokens.language.interaction.ink;
    return SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurface.withValues(alpha: .38);
        }
        if (states.contains(WidgetState.selected)) {
          return toggle.fill == FillKind.outline
              ? scheme.primary
              : scheme.onPrimary;
        }
        return scheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurface.withValues(alpha: .12);
        }
        if (states.contains(WidgetState.selected)) {
          return scheme.primary.withValues(
              alpha: toggle.fill == FillKind.tonal ||
                      toggle.fill == FillKind.glass
                  ? .45
                  : 1);
        }
        return scheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (toggle.borderWidth <= 0) return Colors.transparent;
        final selected = states.contains(WidgetState.selected);
        return (selected ? scheme.primary : scheme.outline)
            .withValues(alpha: toggle.borderAlpha);
      }),
      trackOutlineWidth: WidgetStatePropertyAll(
        toggle.borderWidth > 0 ? toggle.borderWidth : 0,
      ),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (ink == InkKind.none) return Colors.transparent;
        if (states.contains(WidgetState.pressed)) {
          return scheme.primary.withValues(alpha: .12);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return scheme.primary
              .withValues(alpha: tokens.language.interaction.hoverAlpha);
        }
        return null;
      }),
      splashRadius: ink == InkKind.none ? 0 : null,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  static CheckboxThemeData checkboxTheme(
    ColorScheme scheme, {
    required AsemanTokens tokens,
  }) {
    final toggle = tokens.control('checkbox');
    final ink = toggle.ink != InkKind.ripple
        ? toggle.ink
        : tokens.language.interaction.ink;
    final shape = outlinedBorder(
      toggle.copyWith(
        radius: toggle.shape == ShapeKind.stadium
            ? 4
            : (toggle.radius <= 0 ? 2 : toggle.radius.clamp(0, 8)),
        shape: toggle.shape == ShapeKind.stadium
            ? ShapeKind.rounded
            : toggle.shape,
      ),
      sideColor: scheme.primary,
      borderWidth: 0,
    );
    return CheckboxThemeData(
      shape: shape,
      side: BorderSide(
        color: scheme.outline,
        width: toggle.borderWidth > 0 ? toggle.borderWidth : 1.5,
      ),
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll(scheme.onPrimary),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (ink == InkKind.none) return Colors.transparent;
        if (states.contains(WidgetState.pressed)) {
          return scheme.primary.withValues(alpha: .12);
        }
        return scheme.primary
            .withValues(alpha: tokens.language.interaction.hoverAlpha);
      }),
      splashRadius: ink == InkKind.none ? 0 : null,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  static RadioThemeData radioTheme(
    ColorScheme scheme, {
    required AsemanTokens tokens,
  }) {
    final toggle = tokens.control('radio');
    final ink = toggle.ink != InkKind.ripple
        ? toggle.ink
        : tokens.language.interaction.ink;
    return RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return scheme.outline;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (ink == InkKind.none) return Colors.transparent;
        if (states.contains(WidgetState.pressed)) {
          return scheme.primary.withValues(alpha: .12);
        }
        return scheme.primary
            .withValues(alpha: tokens.language.interaction.hoverAlpha);
      }),
      splashRadius: ink == InkKind.none ? 0 : null,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  static SliderThemeData sliderTheme(
    ColorScheme scheme, {
    required AsemanTokens tokens,
  }) {
    final slider = tokens.control('slider');
    final trackH = (slider.minHeight ?? 4).clamp(2, 16).toDouble();
    final thumbR = slider.shape == ShapeKind.sharp || slider.shape == ShapeKind.cut
        ? trackH * .9
        : math.max(8.0, trackH * 1.6);
    return SliderThemeData(
      trackHeight: trackH,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.primary,
      overlayColor: tokens.language.interaction.ink == InkKind.none
          ? Colors.transparent
          : scheme.primary.withValues(alpha: .12),
      trackShape: slider.shape == ShapeKind.sharp ||
              slider.shape == ShapeKind.cut
          ? const RectangularSliderTrackShape()
          : const RoundedRectSliderTrackShape(),
      thumbShape: slider.shape == ShapeKind.sharp ||
              slider.shape == ShapeKind.cut
          ? RoundSliderThumbShape(
              enabledThumbRadius: thumbR,
              elevation: slider.elevation,
              pressedElevation: slider.elevation,
            )
          : RoundSliderThumbShape(
              enabledThumbRadius: thumbR,
              elevation: slider.elevation,
            ),
      overlayShape: tokens.language.interaction.ink == InkKind.none
          ? SliderComponentShape.noOverlay
          : RoundSliderOverlayShape(overlayRadius: thumbR * 1.8),
      valueIndicatorShape: slider.shape == ShapeKind.sharp
          ? const RectangularSliderValueIndicatorShape()
          : const PaddleSliderValueIndicatorShape(),
      showValueIndicator: ShowValueIndicator.onlyForDiscrete,
    );
  }

  /// Floating panel / window / rail shadow + radius from card recipe.
  static BoxDecoration floatingShell(
    BuildContext context, {
    double lift = 0,
    double? radius,
    bool front = false,
  }) {
    final tokens = AsemanTokens.maybeOf(context);
    final card = tokens?.control('card');
    final corners = radius != null
        ? BorderRadius.circular(radius)
        : (card?.borderRadius ??
            BorderRadius.circular(tokens?.radiusCard ?? AppShape.card));
    final base = tokens?.language.shadow.resolve(
          Theme.of(context).colorScheme,
        ) ??
        [
          BoxShadow(
            color: Colors.black.withValues(alpha: .10 + lift * .01),
            blurRadius: 12 + lift * 2,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: .18 + lift * .015),
            blurRadius: 36 + lift * 3,
            offset: const Offset(0, 16),
          ),
        ];
    final shadows = front || lift > 0
        ? [
            for (final s in base)
              BoxShadow(
                color: s.color.withValues(
                    alpha: (s.color.a + (front ? .06 : lift * .01))
                        .clamp(0.0, 1.0)),
                blurRadius: s.blurRadius + (front ? 8 : lift),
                offset: Offset(s.offset.dx, s.offset.dy + (front ? 4 : 0)),
                spreadRadius: s.spreadRadius,
              ),
          ]
        : base;
    return BoxDecoration(borderRadius: corners, boxShadow: shadows);
  }
}

/// Pack-styled switch — Material [Switch] for stadium/rounded languages,
/// rectangular hard-edged control for sharp / cut packs (neo-brutal, etc.).
class PackSwitch extends StatelessWidget {
  const PackSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.showIcons = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool showIcons;

  @override
  Widget build(BuildContext context) {
    final tokens = AsemanTokens.maybeOf(context);
    final toggle = tokens?.control('toggle');
    final sharp = toggle?.shape == ShapeKind.sharp ||
        toggle?.shape == ShapeKind.cut;
    if (sharp && toggle != null) {
      return _PackSharpSwitch(
        value: value,
        onChanged: onChanged,
        recipe: toggle,
        showIcons: showIcons,
      );
    }
    return Switch(
      value: value,
      onChanged: onChanged,
      thumbIcon: showIcons
          ? WidgetStateProperty.resolveWith(
              (s) => Icon(
                s.contains(WidgetState.selected)
                    ? Icons.check_rounded
                    : Icons.close_rounded,
                size: 16,
              ),
            )
          : null,
    );
  }
}

class _PackSharpSwitch extends StatelessWidget {
  const _PackSharpSwitch({
    required this.value,
    required this.onChanged,
    required this.recipe,
    required this.showIcons,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final ControlRecipe recipe;
  final bool showIcons;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = (recipe.minHeight ?? 28).clamp(22.0, 36.0);
    final w = h * 1.85;
    final thumb = h - 8;
    final trackColor = value
        ? scheme.primary
        : scheme.surfaceContainerHighest;
    final thumbColor = value ? scheme.onPrimary : scheme.onSurfaceVariant;
    final shape = ThemeChrome.outlinedBorder(
      recipe,
      sideColor: value ? scheme.primary : scheme.outline,
      borderWidth: recipe.borderWidth > 0 ? recipe.borderWidth : 2,
    );
    final thumbShape = ThemeChrome.outlinedBorder(
      recipe.copyWith(
        radius: recipe.shape == ShapeKind.cut
            ? recipe.radius.clamp(0, 8)
            : 0,
        borderWidth: 0,
      ),
    );
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          width: w,
          height: h,
          padding: const EdgeInsets.all(3),
          decoration: ShapeDecoration(color: trackColor, shape: shape),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: thumb,
              height: thumb,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: thumbColor,
                shape: thumbShape,
                shadows: recipe.elevation > 0
                    ? AsemanTokens.maybeOf(context)
                        ?.language.shadow
                        .resolve(scheme, accent: scheme.primary)
                    : null,
              ),
              child: showIcons
                  ? Icon(
                      value ? Icons.check_rounded : Icons.close_rounded,
                      size: thumb * .55,
                      color: value ? scheme.primary : scheme.surface,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Pack-aware tap target — shape, splash, highlight, optional press scale.
class PackInkWell extends StatefulWidget {
  const PackInkWell({
    super.key,
    required this.child,
    this.onTap,
    this.slot = 'card',
    this.accent,
    this.shape,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String slot;
  final Color? accent;
  final ShapeBorder? shape;

  @override
  State<PackInkWell> createState() => _PackInkWellState();
}

class _PackInkWellState extends State<PackInkWell> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AsemanTokens.maybeOf(context);
    final recipe = tokens?.control(widget.slot);
    final ink = recipe?.ink ??
        tokens?.language.interaction.ink ??
        InkKind.ripple;
    final scale = tokens?.language.interaction.pressScale ?? 1.0;
    final shape = widget.shape ??
        ThemeChrome.shapeOf(
          context,
          slot: widget.slot,
          sideColor: null,
          borderWidth: 0,
        );
    Widget child = Material(
      type: MaterialType.transparency,
      clipBehavior: Clip.antiAlias,
      shape: shape,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: scale != 1
            ? (v) => setState(() => _pressed = v)
            : null,
        customBorder: shape,
        splashFactory: ThemeChrome.splashFactory(context, ink: ink),
        highlightColor:
            ThemeChrome.pressHighlight(context, accent: widget.accent, ink: ink),
        splashColor:
            ThemeChrome.pressSplash(context, accent: widget.accent, ink: ink),
        child: widget.child,
      ),
    );
    if (scale != 1) {
      child = AnimatedScale(
        scale: _pressed ? scale : 1,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: child,
      );
    }
    return child;
  }
}
