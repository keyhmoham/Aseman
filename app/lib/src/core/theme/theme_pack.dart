import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_shape.dart';
import 'app_surfaces.dart';
import 'design_language.dart';
import 'shell_layout.dart';
import 'theme_ui_spec.dart';

/// Schema version for installable theme packs (`decillion.theme/v1`).
const themePackSchema = 'decillion.theme/v1';

/// Maximum serialized pack size accepted from the store / assistant (512 KiB).
const themePackMaxBytes = 512 * 1024;

/// Stable UI part keys for optional per-section accent overrides.
enum ThemePartId {
  nav,
  topBar,
  feed,
  chat,
  desk,
  admin,
  market,
  auth,
  settings,
  selection,
  identity,
  halo,
  fab,
  links,
  bubbles;

  String get jsonKey => switch (this) {
        topBar => 'top_bar',
        _ => name,
      };

  String get label => switch (this) {
        nav => 'Navigation',
        topBar => 'Top bar',
        feed => 'Feed',
        chat => 'Chat',
        desk => 'Desk',
        admin => 'Admin',
        market => 'Market',
        auth => 'Auth',
        settings => 'Settings',
        selection => 'Selection',
        identity => 'Identity marks',
        halo => 'Avatar halos',
        fab => 'FABs',
        links => 'Links',
        bubbles => 'Chat bubbles',
      };

  static ThemePartId? tryParse(String raw) {
    final key = raw.trim().toLowerCase().replaceAll('-', '_');
    for (final part in ThemePartId.values) {
      if (part.jsonKey == key || part.name.toLowerCase() == key) return part;
    }
    return null;
  }
}

/// Optional accent colours for one UI part.
@immutable
class ThemePartColor {
  const ThemePartColor({required this.accent, this.secondary});

  final Color accent;
  final Color? secondary;

  Map<String, dynamic> toJson() => {
        'accent': colorToHex(accent),
        if (secondary != null) 'secondary': colorToHex(secondary!),
      };

  factory ThemePartColor.fromJson(Map<String, dynamic> json) => ThemePartColor(
        accent: parseColor(json['accent']) ?? AppColors.primary,
        secondary: parseColor(json['secondary'] ?? json['secondary_accent']),
      );
}

/// Pack-level part colouring: unified single accent by default, optional
/// per-part overrides when [unified] is false (or overrides are set).
@immutable
class ThemePartColors {
  const ThemePartColors({
    this.unified = true,
    this.overrides = const {},
  });

  /// When true (default), every part resolves to the selected palette accent.
  final bool unified;

  /// Per-part accents. Ignored while [unified] is true.
  final Map<ThemePartId, ThemePartColor> overrides;

  bool get isDefault => unified && overrides.isEmpty;

  ThemePartColors copyWith({
    bool? unified,
    Map<ThemePartId, ThemePartColor>? overrides,
  }) =>
      ThemePartColors(
        unified: unified ?? this.unified,
        overrides: overrides ?? this.overrides,
      );

  /// Resolve the accent for [part] given the active palette [fallback].
  Color accentFor(ThemePartId part, Color fallback) {
    if (unified) return fallback;
    return overrides[part]?.accent ?? fallback;
  }

  Color? secondaryFor(ThemePartId part, Color fallback) {
    if (unified) return fallback;
    return overrides[part]?.secondary ?? overrides[part]?.accent ?? fallback;
  }

  Map<String, dynamic> toJson() {
    if (isDefault) return const {};
    return {
      'unified': unified,
      if (overrides.isNotEmpty)
        'overrides': {
          for (final e in overrides.entries) e.key.jsonKey: e.value.toJson(),
        },
    };
  }

  factory ThemePartColors.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return const ThemePartColors();
    final overrides = <ThemePartId, ThemePartColor>{};
    final raw = json['overrides'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final id = ThemePartId.tryParse('${e.key}');
        if (id == null || e.value is! Map) continue;
        overrides[id] =
            ThemePartColor.fromJson(Map<String, dynamic>.from(e.value as Map));
      }
    }
    final unifiedRaw = json['unified'];
    final unified = unifiedRaw is bool
        ? unifiedRaw
        : overrides.isEmpty; // empty overrides ⇒ unified
    return ThemePartColors(unified: unified, overrides: overrides);
  }
}

/// One selectable color story proposed by a theme pack (settings swatches).
@immutable
class ThemePaletteOption {
  const ThemePaletteOption({
    required this.id,
    required this.label,
    required this.accent,
    this.secondary,
    this.success,
    this.warning,
    this.danger,
    this.accentDark,
  });

  final String id;
  final String label;
  final Color accent;

  /// Accent for dark mode when the light one is too deep to read on a dark
  /// surface. Null keeps [accent] in both modes.
  final Color? accentDark;
  final Color? secondary;
  final Color? success;
  final Color? warning;
  final Color? danger;

  /// This option as it applies under [brightness]: dark mode swaps in
  /// [accentDark] when the option has one.
  ThemePaletteOption forBrightness(Brightness brightness) =>
      brightness == Brightness.dark && accentDark != null
          ? ThemePaletteOption(
              id: id,
              label: label,
              accent: accentDark!,
              secondary: secondary,
              success: success,
              warning: warning,
              danger: danger,
            )
          : this;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'accent': colorToHex(accent),
        if (accentDark != null) 'accent_dark': colorToHex(accentDark!),
        if (secondary != null) 'secondary': colorToHex(secondary!),
        if (success != null) 'success': colorToHex(success!),
        if (warning != null) 'warning': colorToHex(warning!),
        if (danger != null) 'danger': colorToHex(danger!),
      };

  factory ThemePaletteOption.fromJson(Map<String, dynamic> json) =>
      ThemePaletteOption(
        id: '${json['id'] ?? ''}',
        label: '${json['label'] ?? json['id'] ?? 'Accent'}',
        accent: parseColor(json['accent']) ?? AppColors.primary,
        accentDark: parseColor(json['accent_dark']),
        secondary: parseColor(json['secondary'] ?? json['secondary_accent']),
        success: parseColor(json['success']),
        warning: parseColor(json['warning']),
        danger: parseColor(json['danger']),
      );
}

/// Declarative theme pack: visual tokens, graphics, component styles, shell.
@immutable
class ThemePack {
  const ThemePack({
    required this.meta,
    required this.tokens,
    this.language = const DesignLanguage(),
    this.graphics = const ThemeGraphics(),
    this.components = const {},
    this.shell = const ShellLayoutSpec(),
    this.bridges = const ThemeBridges(),
    this.palettes = const [],
    this.parts = const ThemePartColors(),
    this.ui = const ThemeUiSpec(),
  });

  final ThemePackMeta meta;
  final ThemeTokenSet tokens;
  /// Design language recipes that reshape controls beyond raw color tokens.
  final DesignLanguage language;
  final ThemeGraphics graphics;
  final Map<String, ComponentStyle> components;
  final ShellLayoutSpec shell;
  final ThemeBridges bridges;

  /// Dedicated accent / status palettes this pack offers in Settings.
  final List<ThemePaletteOption> palettes;

  /// Unified accent (default) or optional per-part colour overrides.
  final ThemePartColors parts;

  /// Disable built-in slots / attach Elpian surfaces to shell chrome.
  final ThemeUiSpec ui;

  String get id => meta.id;

  /// Palettes to show in Settings (pack list, or a single default from tokens).
  List<ThemePaletteOption> get selectablePalettes {
    if (palettes.isNotEmpty) return palettes;
    final accent = tokens.light.accent ?? AppColors.primary;
    return [
      ThemePaletteOption(
        id: 'default',
        label: 'Default',
        accent: accent,
        secondary: tokens.light.secondaryAccent,
        success: tokens.light.success,
        warning: tokens.light.warning,
        danger: tokens.light.danger,
      ),
    ];
  }

  ThemePaletteOption get defaultPalette => selectablePalettes.first;

  ThemePaletteOption resolvePalette({String? paletteId, Color? accent}) {
    final options = selectablePalettes;
    if (paletteId != null && paletteId.isNotEmpty) {
      for (final opt in options) {
        if (opt.id == paletteId) return opt;
      }
    }
    if (accent != null) {
      for (final opt in options) {
        if (opt.accent.toARGB32() == accent.toARGB32()) return opt;
      }
    }
    return options.first;
  }

  ThemePack copyWith({
    ThemePackMeta? meta,
    ThemeTokenSet? tokens,
    DesignLanguage? language,
    ThemeGraphics? graphics,
    Map<String, ComponentStyle>? components,
    ShellLayoutSpec? shell,
    ThemeBridges? bridges,
    List<ThemePaletteOption>? palettes,
    ThemePartColors? parts,
    ThemeUiSpec? ui,
  }) =>
      ThemePack(
        meta: meta ?? this.meta,
        tokens: tokens ?? this.tokens,
        language: language ?? this.language,
        graphics: graphics ?? this.graphics,
        components: components ?? this.components,
        shell: shell ?? this.shell,
        bridges: bridges ?? this.bridges,
        palettes: palettes ?? this.palettes,
        parts: parts ?? this.parts,
        ui: ui ?? this.ui,
      );

  Map<String, dynamic> toJson() {
    final partsJson = parts.toJson();
    final uiJson = ui.toJson();
    return {
      'schema': themePackSchema,
      'meta': meta.toJson(),
      'language': language.toJson(),
      'tokens': tokens.toJson(),
      'graphics': graphics.toJson(),
      if (components.isNotEmpty)
        'components': {
          for (final e in components.entries) e.key: e.value.toJson(),
        },
      'shell': shell.toJson(),
      if (!bridges.isEmpty) 'bridges': bridges.toJson(),
      if (palettes.isNotEmpty)
        'palettes': palettes.map((p) => p.toJson()).toList(),
      if (partsJson.isNotEmpty) 'parts': partsJson,
      if (uiJson.isNotEmpty) 'ui': uiJson,
    };
  }

  String encode() => jsonEncode(toJson());

  static ThemePack decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('theme pack must be a JSON object');
    }
    return fromJson(Map<String, dynamic>.from(decoded));
  }

  static ThemePack? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return decode(raw);
    } catch (_) {
      return null;
    }
  }

  static ThemePack fromJson(Map<String, dynamic> json) {
    final schema = '${json['schema'] ?? themePackSchema}';
    if (schema != themePackSchema) {
      throw FormatException('unsupported theme schema: $schema');
    }
    final metaRaw = json['meta'];
    if (metaRaw is! Map) {
      throw const FormatException('theme pack meta required');
    }
    final tokensRaw = json['tokens'];
    if (tokensRaw is! Map) {
      throw const FormatException('theme pack tokens required');
    }
    final components = <String, ComponentStyle>{};
    final componentsRaw = json['components'];
    if (componentsRaw is Map) {
      for (final e in componentsRaw.entries) {
        if (e.value is Map) {
          components['${e.key}'] =
              ComponentStyle.fromJson(Map<String, dynamic>.from(e.value as Map));
        }
      }
    }
    final palettes = <ThemePaletteOption>[];
    final palettesRaw = json['palettes'];
    if (palettesRaw is List) {
      for (final item in palettesRaw) {
        if (item is Map) {
          final opt =
              ThemePaletteOption.fromJson(Map<String, dynamic>.from(item));
          if (opt.id.isNotEmpty) palettes.add(opt);
        }
      }
    }
    return ThemePack(
      meta: ThemePackMeta.fromJson(Map<String, dynamic>.from(metaRaw)),
      tokens: ThemeTokenSet.fromJson(Map<String, dynamic>.from(tokensRaw)),
      language: DesignLanguage.fromJson(
        json['language'] is Map
            ? Map<String, dynamic>.from(json['language'] as Map)
            : const {},
      ),
      graphics: ThemeGraphics.fromJson(
        json['graphics'] is Map
            ? Map<String, dynamic>.from(json['graphics'] as Map)
            : const {},
      ),
      components: components,
      shell: ShellLayoutSpec.fromJson(
        json['shell'] is Map
            ? Map<String, dynamic>.from(json['shell'] as Map)
            : const {},
      ),
      bridges: ThemeBridges.fromJson(
        json['bridges'] is Map
            ? Map<String, dynamic>.from(json['bridges'] as Map)
            : const {},
      ),
      palettes: palettes,
      parts: ThemePartColors.fromJson(
        json['parts'] is Map
            ? Map<String, dynamic>.from(json['parts'] as Map)
            : null,
      ),
      ui: ThemeUiSpec.fromJson(
        json['ui'] is Map
            ? Map<String, dynamic>.from(json['ui'] as Map)
            : null,
      ),
    );
  }

  /// Validates required fields and size; returns an error message or null.
  String? validate() {
    if (meta.id.trim().isEmpty) return 'meta.id required';
    if (meta.name.trim().isEmpty) return 'meta.name required';
    final encoded = encode();
    if (encoded.length > themePackMaxBytes) {
      return 'theme pack exceeds $themePackMaxBytes bytes';
    }
    return null;
  }
}

@immutable
class ThemePackMeta {
  const ThemePackMeta({
    required this.id,
    required this.name,
    this.description = '',
    this.author = '',
    this.previewColors = const [],
    this.minAppVersion = '',
    this.builtin = false,
  });

  final String id;
  final String name;
  final String description;
  final String author;
  final List<Color> previewColors;
  final String minAppVersion;
  final bool builtin;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description.isNotEmpty) 'description': description,
        if (author.isNotEmpty) 'author': author,
        if (previewColors.isNotEmpty)
          'preview_colors': previewColors.map(colorToHex).toList(),
        if (minAppVersion.isNotEmpty) 'min_app_version': minAppVersion,
        if (builtin) 'builtin': true,
      };

  factory ThemePackMeta.fromJson(Map<String, dynamic> json) => ThemePackMeta(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        description: '${json['description'] ?? ''}',
        author: '${json['author'] ?? ''}',
        previewColors: parseColorList(json['preview_colors']),
        minAppVersion: '${json['min_app_version'] ?? ''}',
        builtin: json['builtin'] == true,
      );
}

/// Light + dark token banks for a pack.
@immutable
class ThemeTokenSet {
  const ThemeTokenSet({
    required this.light,
    required this.dark,
  });

  final ThemeTokens light;
  final ThemeTokens dark;

  ThemeTokens forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  Map<String, dynamic> toJson() => {
        'light': light.toJson(),
        'dark': dark.toJson(),
      };

  factory ThemeTokenSet.fromJson(Map<String, dynamic> json) => ThemeTokenSet(
        light: ThemeTokens.fromJson(
          json['light'] is Map
              ? Map<String, dynamic>.from(json['light'] as Map)
              : const {},
        ),
        dark: ThemeTokens.fromJson(
          json['dark'] is Map
              ? Map<String, dynamic>.from(json['dark'] as Map)
              : const {},
        ),
      );
}

/// Visual tokens for one brightness.
@immutable
class ThemeTokens {
  const ThemeTokens({
    this.accent,
    this.secondaryAccent,
    this.scaffold,
    this.surface,
    this.surfaceHigh,
    this.inputFill,
    this.success,
    this.warning,
    this.danger,
    this.cardAlpha = AppSurfaces.cardAlpha,
    this.overlayAlpha = AppSurfaces.overlayAlpha,
    this.blurSigma = AppSurfaces.blurSigma,
    this.barrier,
    this.radiusCard = AppShape.card,
    this.radiusInner = AppShape.inner,
    this.radiusControl = AppShape.control,
    this.radiusFab = AppShape.fab,
    this.radiusFabSmall = AppShape.fabSmall,
    this.radiusFabLarge = AppShape.fabLarge,
    this.density = 0,
    this.spacingScale = 1,
    this.titleWeight = 800,
    this.labelWeight = 700,
    this.letterSpacingDisplay = -0.8,
    this.letterSpacingTitle = -0.35,
    this.fontFamily = '',
    this.motionScale = 1,
    this.reduceMotion = false,
    this.fabMistAlpha,
    this.navHeight = 66,
  });

  final Color? accent;
  final Color? secondaryAccent;
  final Color? scaffold;
  final Color? surface;
  final Color? surfaceHigh;
  final Color? inputFill;
  final Color? success;
  final Color? warning;
  final Color? danger;
  final double cardAlpha;
  final double overlayAlpha;
  final double blurSigma;
  final Color? barrier;
  final double radiusCard;
  final double radiusInner;
  final double radiusControl;
  final double radiusFab;
  final double radiusFabSmall;
  final double radiusFabLarge;
  final double density;
  final double spacingScale;
  final int titleWeight;
  final int labelWeight;
  final double letterSpacingDisplay;
  final double letterSpacingTitle;
  final String fontFamily;
  final double motionScale;
  final bool reduceMotion;
  final double? fabMistAlpha;
  final double navHeight;

  ThemeTokens overlayAccent(Color accent) => overlayPalette(
        ThemePaletteOption(id: 'custom', label: 'Custom', accent: accent),
      );

  /// Applies a pack palette option (accent + optional secondary / status).
  ThemeTokens overlayPalette(ThemePaletteOption palette) => ThemeTokens(
        accent: palette.accent,
        secondaryAccent: palette.secondary ?? secondaryAccent,
        scaffold: scaffold,
        surface: surface,
        surfaceHigh: surfaceHigh,
        inputFill: inputFill,
        success: palette.success ?? success,
        warning: palette.warning ?? warning,
        danger: palette.danger ?? danger,
        cardAlpha: cardAlpha,
        overlayAlpha: overlayAlpha,
        blurSigma: blurSigma,
        barrier: barrier,
        radiusCard: radiusCard,
        radiusInner: radiusInner,
        radiusControl: radiusControl,
        radiusFab: radiusFab,
        radiusFabSmall: radiusFabSmall,
        radiusFabLarge: radiusFabLarge,
        density: density,
        spacingScale: spacingScale,
        titleWeight: titleWeight,
        labelWeight: labelWeight,
        letterSpacingDisplay: letterSpacingDisplay,
        letterSpacingTitle: letterSpacingTitle,
        fontFamily: fontFamily,
        motionScale: motionScale,
        reduceMotion: reduceMotion,
        fabMistAlpha: fabMistAlpha,
        navHeight: navHeight,
      );

  Map<String, dynamic> toJson() => {
        if (accent != null) 'accent': colorToHex(accent!),
        if (secondaryAccent != null)
          'secondary_accent': colorToHex(secondaryAccent!),
        if (scaffold != null) 'scaffold': colorToHex(scaffold!),
        if (surface != null) 'surface': colorToHex(surface!),
        if (surfaceHigh != null) 'surface_high': colorToHex(surfaceHigh!),
        if (inputFill != null) 'input_fill': colorToHex(inputFill!),
        if (success != null) 'success': colorToHex(success!),
        if (warning != null) 'warning': colorToHex(warning!),
        if (danger != null) 'danger': colorToHex(danger!),
        'card_alpha': cardAlpha,
        'overlay_alpha': overlayAlpha,
        'blur_sigma': blurSigma,
        if (barrier != null) 'barrier': colorToHex(barrier!),
        'radius_card': radiusCard,
        'radius_inner': radiusInner,
        'radius_control': radiusControl,
        'radius_fab': radiusFab,
        'radius_fab_small': radiusFabSmall,
        'radius_fab_large': radiusFabLarge,
        if (density != 0) 'density': density,
        if (spacingScale != 1) 'spacing_scale': spacingScale,
        'title_weight': titleWeight,
        'label_weight': labelWeight,
        'letter_spacing_display': letterSpacingDisplay,
        'letter_spacing_title': letterSpacingTitle,
        if (fontFamily.isNotEmpty) 'font_family': fontFamily,
        if (motionScale != 1) 'motion_scale': motionScale,
        if (reduceMotion) 'reduce_motion': true,
        if (fabMistAlpha != null) 'fab_mist_alpha': fabMistAlpha,
        'nav_height': navHeight,
      };

  factory ThemeTokens.fromJson(Map<String, dynamic> json) => ThemeTokens(
        accent: parseColor(json['accent']),
        secondaryAccent: parseColor(json['secondary_accent']),
        scaffold: parseColor(json['scaffold']),
        surface: parseColor(json['surface']),
        surfaceHigh: parseColor(json['surface_high']),
        inputFill: parseColor(json['input_fill']),
        success: parseColor(json['success']),
        warning: parseColor(json['warning']),
        danger: parseColor(json['danger']),
        cardAlpha: parseDouble(json['card_alpha'], AppSurfaces.cardAlpha),
        overlayAlpha:
            parseDouble(json['overlay_alpha'], AppSurfaces.overlayAlpha),
        blurSigma: parseDouble(json['blur_sigma'], AppSurfaces.blurSigma),
        barrier: parseColor(json['barrier']),
        radiusCard: parseDouble(json['radius_card'], AppShape.card),
        radiusInner: parseDouble(json['radius_inner'], AppShape.inner),
        radiusControl: parseDouble(json['radius_control'], AppShape.control),
        radiusFab: parseDouble(json['radius_fab'], AppShape.fab),
        radiusFabSmall: parseDouble(json['radius_fab_small'], AppShape.fabSmall),
        radiusFabLarge: parseDouble(json['radius_fab_large'], AppShape.fabLarge),
        density: parseDouble(json['density'], 0),
        spacingScale: parseDouble(json['spacing_scale'], 1),
        titleWeight: parseInt(json['title_weight'], 800),
        labelWeight: parseInt(json['label_weight'], 700),
        letterSpacingDisplay:
            parseDouble(json['letter_spacing_display'], -0.8),
        letterSpacingTitle: parseDouble(json['letter_spacing_title'], -0.35),
        fontFamily: '${json['font_family'] ?? ''}',
        motionScale: parseDouble(json['motion_scale'], 1),
        reduceMotion: json['reduce_motion'] == true,
        fabMistAlpha: json['fab_mist_alpha'] == null
            ? null
            : parseDouble(json['fab_mist_alpha'], 0.14),
        navHeight: parseDouble(json['nav_height'], 66),
      );
}

@immutable
class ThemeGraphics {
  const ThemeGraphics({
    this.atmosphere = 'sky',
    this.haloStyle = 'ring',
    this.iconTreatment = 'rounded',
    this.painters = const {},
    this.grain = 0,
    this.sheen = 0,
    this.vignette = 0,
    this.parallax = 0,
    this.bloom = 0,
    this.scanlines = 0,
    this.noiseSeed = 0,
    this.backdropStyle = 'auto',
  });

  final String atmosphere;
  final String haloStyle;
  final String iconTreatment;
  final Map<String, String> painters;

  /// Global surface grain / sheen / vignette / parallax (0–1).
  final double grain;
  final double sheen;
  final double vignette;
  final double parallax;
  final double bloom;
  final double scanlines;
  final int noiseSeed;

  /// auto | frost | solid | flat | none
  final String backdropStyle;

  Map<String, dynamic> toJson() => {
        'atmosphere': atmosphere,
        'halo_style': haloStyle,
        'icon_treatment': iconTreatment,
        if (painters.isNotEmpty) 'painters': painters,
        if (grain > 0) 'grain': grain,
        if (sheen > 0) 'sheen': sheen,
        if (vignette > 0) 'vignette': vignette,
        if (parallax > 0) 'parallax': parallax,
        if (bloom > 0) 'bloom': bloom,
        if (scanlines > 0) 'scanlines': scanlines,
        if (noiseSeed != 0) 'noise_seed': noiseSeed,
        if (backdropStyle != 'auto') 'backdrop_style': backdropStyle,
      };

  factory ThemeGraphics.fromJson(Map<String, dynamic> json) => ThemeGraphics(
        atmosphere: '${json['atmosphere'] ?? 'sky'}',
        haloStyle: '${json['halo_style'] ?? 'ring'}',
        iconTreatment: '${json['icon_treatment'] ?? 'rounded'}',
        painters: json['painters'] is Map
            ? {
                for (final e in (json['painters'] as Map).entries)
                  '${e.key}': '${e.value}',
              }
            : const {},
        grain: parseDouble(json['grain'], 0),
        sheen: parseDouble(json['sheen'], 0),
        vignette: parseDouble(json['vignette'], 0),
        parallax: parseDouble(json['parallax'], 0),
        bloom: parseDouble(json['bloom'], 0),
        scanlines: parseDouble(json['scanlines'], 0),
        noiseSeed: parseInt(json['noise_seed'], 0),
        backdropStyle: '${json['backdrop_style'] ?? 'auto'}',
      );
}

@immutable
class ComponentStyle {
  const ComponentStyle({
    this.radius,
    this.elevation,
    this.padding,
    this.paddingV,
    this.useGlass,
    this.accentRef,
    this.groupAs,
    this.shapeKind,
    this.fillKind,
    this.borderWidth,
    this.borderAlpha,
    this.inkKind,
    this.minHeight,
    this.accentRole,
    this.effects,
    this.motion,
    this.typography,
    this.iconography,
    this.states,
    this.gradient,
  });

  final double? radius;
  final double? elevation;
  final double? padding;
  final double? paddingV;
  final bool? useGlass;
  final String? accentRef;
  /// How to present this slot in chrome: tab, page, section, rail, drawer.
  final String? groupAs;
  final ShapeKind? shapeKind;
  final FillKind? fillKind;
  final double? borderWidth;
  final double? borderAlpha;
  final InkKind? inkKind;
  final double? minHeight;
  final AccentRole? accentRole;
  final ControlEffects? effects;
  final ControlMotion? motion;
  final ControlTypography? typography;
  final ControlIconography? iconography;
  final ControlStates? states;
  final GradientSpec? gradient;

  Map<String, dynamic> toJson() => {
        if (radius != null) 'radius': radius,
        if (elevation != null) 'elevation': elevation,
        if (padding != null) 'padding': padding,
        if (paddingV != null) 'padding_v': paddingV,
        if (useGlass != null) 'use_glass': useGlass,
        if (accentRef != null) 'accent_ref': accentRef,
        if (groupAs != null) 'group_as': groupAs,
        if (shapeKind != null) 'shape': shapeKind!.name,
        if (fillKind != null) 'fill': fillKind!.name,
        if (borderWidth != null) 'border_width': borderWidth,
        if (borderAlpha != null) 'border_alpha': borderAlpha,
        if (inkKind != null) 'ink': inkKind!.name,
        if (minHeight != null) 'min_height': minHeight,
        if (accentRole != null) 'accent': accentRole!.name,
        if (effects != null && !effects!.isIdentity)
          'effects': effects!.toJson(),
        if (motion != null && !motion!.isIdentity) 'motion': motion!.toJson(),
        if (typography != null && !typography!.isEmpty)
          'typography': typography!.toJson(),
        if (iconography != null && !iconography!.isEmpty)
          'iconography': iconography!.toJson(),
        if (states != null && !states!.isEmpty) 'states': states!.toJson(),
        if (gradient != null && !gradient!.isEmpty)
          'gradient': gradient!.toJson(),
      };

  factory ComponentStyle.fromJson(Map<String, dynamic> json) {
    FillKind? fill;
    if (json['use_glass'] == true) {
      fill = FillKind.glass;
    } else if (json['fill'] != null) {
      fill = ControlRecipe.fromJson({'fill': json['fill']}).fill;
    }
    return ComponentStyle(
      radius: json['radius'] == null ? null : parseDouble(json['radius'], 0),
      elevation: json['elevation'] == null
          ? null
          : parseDouble(json['elevation'], 0),
      padding:
          json['padding'] == null ? null : parseDouble(json['padding'], 0),
      paddingV:
          json['padding_v'] == null ? null : parseDouble(json['padding_v'], 0),
      useGlass: json['use_glass'] is bool ? json['use_glass'] as bool : null,
      accentRef: json['accent_ref']?.toString(),
      groupAs: json['group_as']?.toString(),
      shapeKind: json['shape'] == null
          ? null
          : ControlRecipe.fromJson({'shape': json['shape']}).shape,
      fillKind: fill,
      borderWidth: json['border_width'] == null
          ? null
          : parseDouble(json['border_width'], 0),
      borderAlpha: json['border_alpha'] == null
          ? null
          : parseDouble(json['border_alpha'], 0),
      inkKind: json['ink'] == null
          ? null
          : ControlRecipe.fromJson({'ink': json['ink']}).ink,
      minHeight: json['min_height'] == null
          ? null
          : parseDouble(json['min_height'], 0),
      accentRole: json['accent'] == null
          ? null
          : ControlRecipe.fromJson({'accent': json['accent']}).accentRole,
      effects: json['effects'] is Map
          ? ControlEffects.fromJson(
              Map<String, dynamic>.from(json['effects'] as Map))
          : null,
      motion: json['motion'] is Map
          ? ControlMotion.fromJson(
              Map<String, dynamic>.from(json['motion'] as Map))
          : null,
      typography: json['typography'] is Map
          ? ControlTypography.fromJson(
              Map<String, dynamic>.from(json['typography'] as Map))
          : null,
      iconography: json['iconography'] is Map
          ? ControlIconography.fromJson(
              Map<String, dynamic>.from(json['iconography'] as Map))
          : null,
      states: json['states'] is Map
          ? ControlStates.fromJson(
              Map<String, dynamic>.from(json['states'] as Map))
          : null,
      gradient: json['gradient'] is Map
          ? GradientSpec.fromJson(
              Map<String, dynamic>.from(json['gradient'] as Map))
          : null,
    );
  }
}

@immutable
class ThemeBridges {
  const ThemeBridges({
    this.elpian = const {},
    this.agui = const {},
    this.viz = const {},
  });

  final Map<String, String> elpian;
  final Map<String, String> agui;
  final Map<String, String> viz;

  bool get isEmpty => elpian.isEmpty && agui.isEmpty && viz.isEmpty;

  Map<String, dynamic> toJson() => {
        if (elpian.isNotEmpty) 'elpian': elpian,
        if (agui.isNotEmpty) 'agui': agui,
        if (viz.isNotEmpty) 'viz': viz,
      };

  factory ThemeBridges.fromJson(Map<String, dynamic> json) => ThemeBridges(
        elpian: _stringMap(json['elpian']),
        agui: _stringMap(json['agui']),
        viz: _stringMap(json['viz']),
      );

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const {};
    return {for (final e in raw.entries) '${e.key}': '${e.value}'};
  }
}

String colorToHex(Color c) =>
    c.toARGB32().toRadixString(16).padLeft(8, '0');

Color? parseColor(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return Color(raw);
  if (raw is! String) return null;
  var hex = raw.startsWith('#') ? raw.substring(1) : raw;
  if (hex.length == 6) hex = 'ff$hex';
  if (hex.length != 8) return null;
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return Color(value);
}

List<Color> parseColorList(Object? raw) {
  if (raw is! List) return const [];
  final out = <Color>[];
  for (final item in raw) {
    final c = parseColor(item);
    if (c != null) out.add(c);
  }
  return out;
}

double parseDouble(Object? raw, double fallback) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw) ?? fallback;
  return fallback;
}

int parseInt(Object? raw, int fallback) {
  if (raw is int) return raw;
  if (raw is num) return raw.round();
  if (raw is String) return int.tryParse(raw) ?? fallback;
  return fallback;
}

/// Default Sky tokens — neutral greys; accent lives only on interactive chrome.
ThemeTokens skyLightTokens({Color? accent}) => ThemeTokens(
      accent: accent ?? AppColors.primary,
      secondaryAccent: AppColors.cyan,
      scaffold: const Color(0xFFF3F3F5),
      surface: const Color(0xFFFBFBFC),
      surfaceHigh: const Color(0xFFFFFFFF),
      inputFill: Colors.white,
      cardAlpha: 0.96,
      overlayAlpha: 0.88,
      blurSigma: 16,
      success: AppColors.success,
      warning: AppColors.warning,
      danger: AppColors.danger,
    );

ThemeTokens skyDarkTokens({Color? accent}) => ThemeTokens(
      accent: accent ?? AppColors.primary,
      secondaryAccent: AppColors.cyan,
      scaffold: const Color(0xFF0A0A0C),
      surface: const Color(0xFF141418),
      surfaceHigh: const Color(0xFF1C1C22),
      inputFill: const Color(0xFF1C1C22),
      cardAlpha: 0.92,
      overlayAlpha: 0.86,
      blurSigma: 18,
      success: AppColors.success,
      warning: AppColors.warning,
      danger: AppColors.danger,
    );
