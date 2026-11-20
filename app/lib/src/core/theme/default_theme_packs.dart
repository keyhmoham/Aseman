import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'design_language.dart';
import 'shell_layout.dart';
import 'theme_pack.dart';

/// Built-in packs shipped with the app (Paper default + design-language samples).
abstract final class DefaultThemePacks {
  static const skyId = 'builtin.sky';
  static const paperId = 'builtin.paper';
  static const kashiId = 'builtin.kashi';

  /// Flat, print-like packs (no glass, no glow, solid hairline surfaces).
  static bool isFlat(String? id) => id == paperId || id == kashiId;
  static const contrastId = 'builtin.high_contrast';
  static const compactId = 'builtin.compact';
  static const fluentId = 'builtin.fluent';
  static const neoBrutalId = 'builtin.neo_brutal';
  static const cupertinoId = 'builtin.cupertino';

  static ThemePack get sky => ThemePack(
        meta: const ThemePackMeta(
          id: skyId,
          name: 'Sky',
          description: 'Default Aseman glass and Material 3 Expressive look.',
          author: 'Aseman',
          previewColors: [
            AppColors.primary,
            AppColors.cyan,
            Color(0xFFF1F0F7),
          ],
          builtin: true,
        ),
        language: DesignLanguage.presetOf(DesignLanguage.materialExpressive),
        tokens: ThemeTokenSet(
          light: skyLightTokens(),
          dark: skyDarkTokens(),
        ),
        graphics: const ThemeGraphics(
          atmosphere: 'mist',
          backdropStyle: 'solid',
        ),
        shell: const ShellLayoutSpec(),
        // Accents colour interactive chrome only — surfaces stay neutral greys.
        // Blue is first so [ThemePack.defaultPalette] matches the app default.
        palettes: const [
          ThemePaletteOption(
            id: 'blue',
            label: 'Blue',
            accent: AppColors.primary,
            secondary: Color(0xFF6B7280),
            success: AppColors.success,
            warning: AppColors.warning,
            danger: AppColors.danger,
          ),
          ThemePaletteOption(
            id: 'violet',
            label: 'Violet',
            accent: AppColors.violet,
            secondary: Color(0xFF6B7280),
            success: AppColors.success,
            warning: AppColors.warning,
            danger: AppColors.danger,
          ),
          ThemePaletteOption(
            id: 'teal',
            label: 'Teal',
            accent: Color(0xFF0D9488),
            secondary: Color(0xFF6B7280),
            success: AppColors.success,
            warning: AppColors.warning,
            danger: AppColors.danger,
          ),
          ThemePaletteOption(
            id: 'rose',
            label: 'Rose',
            accent: Color(0xFFE11D48),
            secondary: Color(0xFF6B7280),
            success: AppColors.success,
            warning: AppColors.warning,
            danger: AppColors.danger,
          ),
          ThemePaletteOption(
            id: 'ink',
            label: 'Ink',
            accent: Color(0xFF111827),
            secondary: Color(0xFF6B7280),
            success: AppColors.success,
            warning: AppColors.warning,
            danger: AppColors.danger,
          ),
        ],
      );

  static ThemePack get highContrast => ThemePack(
        meta: const ThemePackMeta(
          id: contrastId,
          name: 'High contrast',
          description: 'Stronger borders, denser ink, reduced glass blur.',
          author: 'Aseman',
          previewColors: [
            Color(0xFF000000),
            Color(0xFFFFFFFF),
            Color(0xFF1565C0),
          ],
          builtin: true,
        ),
        language: DesignLanguage.presetOf(DesignLanguage.flat),
        tokens: const ThemeTokenSet(
          light: ThemeTokens(
            accent: Color(0xFF0D47A1),
            secondaryAccent: Color(0xFF455A64),
            scaffold: Color(0xFFF5F5F5),
            surface: Colors.white,
            inputFill: Colors.white,
            cardAlpha: 1,
            overlayAlpha: 1,
            blurSigma: 0,
            radiusCard: 12,
            radiusInner: 10,
            radiusControl: 8,
            success: Color(0xFF1B5E20),
            warning: Color(0xFFE65100),
            danger: Color(0xFFB71C1C),
            titleWeight: 900,
            labelWeight: 800,
          ),
          dark: ThemeTokens(
            accent: Color(0xFF90CAF9),
            secondaryAccent: Color(0xFFB0BEC5),
            scaffold: Color(0xFF000000),
            surface: Color(0xFF121212),
            surfaceHigh: Color(0xFF1E1E1E),
            inputFill: Color(0xFF1E1E1E),
            cardAlpha: 1,
            overlayAlpha: 1,
            blurSigma: 0,
            radiusCard: 12,
            radiusInner: 10,
            radiusControl: 8,
            success: Color(0xFF81C784),
            warning: Color(0xFFFFB74D),
            danger: Color(0xFFEF9A9A),
            titleWeight: 900,
            labelWeight: 800,
          ),
        ),
        graphics: const ThemeGraphics(
          atmosphere: 'flat',
          haloStyle: 'square',
          iconTreatment: 'sharp',
          backdropStyle: 'solid',
        ),
        shell: const ShellLayoutSpec(),
        palettes: const [
          ThemePaletteOption(
            id: 'blue',
            label: 'Blue',
            accent: Color(0xFF0D47A1),
            secondary: Color(0xFF455A64),
            success: Color(0xFF1B5E20),
            warning: Color(0xFFE65100),
            danger: Color(0xFFB71C1C),
          ),
          ThemePaletteOption(
            id: 'ink',
            label: 'Ink',
            accent: Color(0xFF111111),
            secondary: Color(0xFF455A64),
            success: Color(0xFF1B5E20),
            warning: Color(0xFFE65100),
            danger: Color(0xFFB71C1C),
          ),
          ThemePaletteOption(
            id: 'forest',
            label: 'Forest',
            accent: Color(0xFF1B5E20),
            secondary: Color(0xFF455A64),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFE65100),
            danger: Color(0xFFB71C1C),
          ),
          ThemePaletteOption(
            id: 'amber',
            label: 'Amber',
            accent: Color(0xFFE65100),
            secondary: Color(0xFF455A64),
            success: Color(0xFF1B5E20),
            warning: Color(0xFFFF6F00),
            danger: Color(0xFFB71C1C),
          ),
        ],
      );

  static ThemePack get compact => ThemePack(
        meta: const ThemePackMeta(
          id: compactId,
          name: 'Compact',
          description: 'Tighter spacing, smaller radii, phone tabs reordered.',
          author: 'Aseman',
          previewColors: [
            Color(0xFF5C6BC0),
            Color(0xFF26A69A),
            Color(0xFFE8EAF6),
          ],
          builtin: true,
        ),
        language: DesignLanguage.presetOf(DesignLanguage.denseModern),
        tokens: const ThemeTokenSet(
          light: ThemeTokens(
            accent: Color(0xFF4F46E5),
            secondaryAccent: Color(0xFF64748B),
            scaffold: Color(0xFFF4F4F5),
            surface: Color(0xFFFAFAFA),
            radiusCard: 16,
            radiusInner: 12,
            radiusControl: 10,
            radiusFab: 12,
            radiusFabSmall: 10,
            radiusFabLarge: 18,
            spacingScale: 0.85,
            density: -1,
            navHeight: 58,
            cardAlpha: 0.98,
            overlayAlpha: 0.9,
            blurSigma: 14,
          ),
          dark: ThemeTokens(
            accent: Color(0xFF818CF8),
            secondaryAccent: Color(0xFF94A3B8),
            scaffold: Color(0xFF09090B),
            surface: Color(0xFF141416),
            surfaceHigh: Color(0xFF1C1C1F),
            radiusCard: 16,
            radiusInner: 12,
            radiusControl: 10,
            radiusFab: 12,
            radiusFabSmall: 10,
            radiusFabLarge: 18,
            spacingScale: 0.85,
            density: -1,
            navHeight: 58,
            cardAlpha: 0.96,
            overlayAlpha: 0.9,
            blurSigma: 12,
          ),
        ),
        graphics: const ThemeGraphics(
          atmosphere: 'flat',
          backdropStyle: 'solid',
        ),
        shell: const ShellLayoutSpec(
          home: HomeShellSpec(
            phoneTabs: [
              FeatureSlots.homeExplore,
              FeatureSlots.homeChats,
              FeatureSlots.homeYou,
            ],
            composerOn: [FeatureSlots.homeExplore],
          ),
          store: StoreShellSpec(
            tabs: [
              FeatureSlots.storeThemes,
              FeatureSlots.storeDiscover,
              FeatureSlots.storeLibrary,
            ],
          ),
        ),
        palettes: const [
          ThemePaletteOption(
            id: 'indigo',
            label: 'Indigo',
            accent: Color(0xFF4F46E5),
            secondary: Color(0xFF64748B),
          ),
          ThemePaletteOption(
            id: 'teal',
            label: 'Teal',
            accent: Color(0xFF0D9488),
            secondary: Color(0xFF64748B),
          ),
          ThemePaletteOption(
            id: 'slate',
            label: 'Slate',
            accent: Color(0xFF334155),
            secondary: Color(0xFF64748B),
          ),
          ThemePaletteOption(
            id: 'rose',
            label: 'Rose',
            accent: Color(0xFFE11D48),
            secondary: Color(0xFF64748B),
          ),
        ],
      );

  static ThemePack get fluent => ThemePack(
        meta: const ThemePackMeta(
          id: fluentId,
          name: 'Fluent',
          description: 'Sharp-ish corners, compact controls, highlight ink.',
          author: 'Aseman',
          previewColors: [
            Color(0xFF0078D4),
            Color(0xFF106EBE),
            Color(0xFFF3F2F1),
          ],
          builtin: true,
        ),
        language: DesignLanguage.presetOf(DesignLanguage.fluent),
        tokens: const ThemeTokenSet(
          light: ThemeTokens(
            accent: Color(0xFF0078D4),
            secondaryAccent: Color(0xFF605E5C),
            scaffold: Color(0xFFF3F2F1),
            surface: Color(0xFFFFFFFF),
            radiusCard: 8,
            radiusInner: 6,
            radiusControl: 4,
            radiusFab: 4,
            cardAlpha: 1,
            overlayAlpha: 0.98,
            blurSigma: 0,
            density: -1,
            navHeight: 48,
            titleWeight: 600,
            labelWeight: 600,
            letterSpacingDisplay: -0.2,
            letterSpacingTitle: -0.1,
          ),
          dark: ThemeTokens(
            accent: Color(0xFF4CC2FF),
            secondaryAccent: Color(0xFFA19F9D),
            scaffold: Color(0xFF1F1F1F),
            surface: Color(0xFF292929),
            radiusCard: 8,
            radiusInner: 6,
            radiusControl: 4,
            radiusFab: 4,
            cardAlpha: 1,
            overlayAlpha: 0.98,
            blurSigma: 0,
            density: -1,
            navHeight: 48,
            titleWeight: 600,
            labelWeight: 600,
          ),
        ),
        graphics: const ThemeGraphics(
          atmosphere: 'flat',
          haloStyle: 'square',
          iconTreatment: 'sharp',
          backdropStyle: 'solid',
        ),
        palettes: const [
          ThemePaletteOption(
            id: 'blue',
            label: 'Blue',
            accent: Color(0xFF0078D4),
            secondary: Color(0xFF605E5C),
          ),
          ThemePaletteOption(
            id: 'purple',
            label: 'Purple',
            accent: Color(0xFF8764B8),
            secondary: Color(0xFF605E5C),
          ),
          ThemePaletteOption(
            id: 'green',
            label: 'Green',
            accent: Color(0xFF107C10),
            secondary: Color(0xFF605E5C),
          ),
          ThemePaletteOption(
            id: 'orange',
            label: 'Orange',
            accent: Color(0xFFD83B01),
            secondary: Color(0xFF605E5C),
          ),
        ],
      );

  static ThemePack get neoBrutal => ThemePack(
        meta: const ThemePackMeta(
          id: neoBrutalId,
          name: 'Neo-brutal',
          description: 'Hard edges, thick borders, offset shadows.',
          author: 'Aseman',
          previewColors: [
            Color(0xFFFFE66D),
            Color(0xFF1A1A1A),
            Color(0xFFFF6B6B),
          ],
          builtin: true,
        ),
        language: DesignLanguage.presetOf(DesignLanguage.neoBrutal),
        tokens: const ThemeTokenSet(
          light: ThemeTokens(
            accent: Color(0xFFFF6B6B),
            secondaryAccent: Color(0xFFE8F07A),
            scaffold: Color(0xFFFFF8E7),
            surface: Color(0xFFFFFFFF),
            radiusCard: 0,
            radiusInner: 0,
            radiusControl: 0,
            radiusFab: 0,
            cardAlpha: 1,
            overlayAlpha: 1,
            blurSigma: 0,
            titleWeight: 900,
            labelWeight: 800,
            letterSpacingDisplay: 0,
            letterSpacingTitle: 0,
          ),
          dark: ThemeTokens(
            accent: Color(0xFFFFE66D),
            secondaryAccent: Color(0xFFFF6B6B),
            scaffold: Color(0xFF0D0D0D),
            surface: Color(0xFF1A1A1A),
            radiusCard: 0,
            radiusInner: 0,
            radiusControl: 0,
            radiusFab: 0,
            cardAlpha: 1,
            overlayAlpha: 1,
            blurSigma: 0,
            titleWeight: 900,
            labelWeight: 800,
          ),
        ),
        graphics: const ThemeGraphics(
          atmosphere: 'flat',
          haloStyle: 'square',
          iconTreatment: 'sharp',
        ),
        palettes: const [
          ThemePaletteOption(
            id: 'coral',
            label: 'Coral',
            accent: Color(0xFFFF6B6B),
            secondary: Color(0xFFE8F07A),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFFFB300),
            danger: Color(0xFFD50000),
          ),
          ThemePaletteOption(
            id: 'yellow',
            label: 'Yellow',
            accent: Color(0xFFFFE66D),
            secondary: Color(0xFFFF6B6B),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFFFB300),
            danger: Color(0xFFD50000),
          ),
          ThemePaletteOption(
            id: 'lime',
            label: 'Lime',
            accent: Color(0xFFB8E63B),
            secondary: Color(0xFFFF6B6B),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFFFB300),
            danger: Color(0xFFD50000),
          ),
          ThemePaletteOption(
            id: 'magenta',
            label: 'Magenta',
            accent: Color(0xFFFF3D81),
            secondary: Color(0xFFE8F07A),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFFFB300),
            danger: Color(0xFFD50000),
          ),
        ],
      );

  static ThemePack get cupertino => ThemePack(
        meta: const ThemePackMeta(
          id: cupertinoId,
          name: 'Cupertino',
          description: 'iOS-like continuous corners and highlight presses.',
          author: 'Aseman',
          previewColors: [
            Color(0xFF007AFF),
            Color(0xFF34C759),
            Color(0xFFF2F2F7),
          ],
          builtin: true,
        ),
        language: DesignLanguage.presetOf(DesignLanguage.cupertino),
        tokens: const ThemeTokenSet(
          light: ThemeTokens(
            accent: Color(0xFF007AFF),
            secondaryAccent: Color(0xFF34C759),
            scaffold: Color(0xFFF2F2F7),
            surface: Color(0xFFFFFFFF),
            radiusCard: 14,
            radiusInner: 12,
            radiusControl: 10,
            radiusFab: 999,
            cardAlpha: 0.92,
            overlayAlpha: 0.94,
            blurSigma: 20,
            titleWeight: 700,
            labelWeight: 600,
            letterSpacingDisplay: -0.4,
            letterSpacingTitle: -0.2,
          ),
          dark: ThemeTokens(
            accent: Color(0xFF0A84FF),
            secondaryAccent: Color(0xFF30D158),
            scaffold: Color(0xFF000000),
            surface: Color(0xFF1C1C1E),
            radiusCard: 14,
            radiusInner: 12,
            radiusControl: 10,
            radiusFab: 999,
            cardAlpha: 0.88,
            overlayAlpha: 0.92,
            blurSigma: 24,
            titleWeight: 700,
            labelWeight: 600,
          ),
        ),
        graphics: const ThemeGraphics(
          atmosphere: 'mist',
          haloStyle: 'ring',
          iconTreatment: 'rounded',
        ),
        palettes: const [
          ThemePaletteOption(
            id: 'blue',
            label: 'Blue',
            accent: Color(0xFF007AFF),
            secondary: Color(0xFF34C759),
          ),
          ThemePaletteOption(
            id: 'purple',
            label: 'Purple',
            accent: Color(0xFFAF52DE),
            secondary: Color(0xFF34C759),
          ),
          ThemePaletteOption(
            id: 'pink',
            label: 'Pink',
            accent: Color(0xFFFF2D55),
            secondary: Color(0xFF5856D6),
          ),
          ThemePaletteOption(
            id: 'teal',
            label: 'Teal',
            accent: Color(0xFF5AC8FA),
            secondary: Color(0xFF34C759),
          ),
          ThemePaletteOption(
            id: 'orange',
            label: 'Orange',
            accent: Color(0xFFFF9500),
            secondary: Color(0xFF007AFF),
          ),
        ],
      );

  /// Flat Material 3 Expressive: warm paper, grey accent, no sky glow or frost.
  static DesignLanguage get paperLanguage {
    final base = DesignLanguage.presetOf(DesignLanguage.materialExpressive);
    ControlRecipe inked(
      ControlRecipe recipe, {
      double elevation = 0,
    }) =>
        recipe.copyWith(
          fill: FillKind.solid,
          elevation: elevation,
          borderWidth: recipe.borderWidth > 0 ? recipe.borderWidth : 1,
          borderAlpha: 1,
        );
    return base.copyWith(
      card: inked(base.card),
      sheet: inked(base.sheet),
      dialog: inked(base.dialog, elevation: 1),
      menu: inked(base.menu, elevation: 1),
      panelHeader: inked(base.panelHeader, elevation: 1),
      navPill: inked(base.navPill),
      fab: base.fab.copyWith(fill: FillKind.solid, elevation: 1),
      input: base.input.copyWith(
        fill: FillKind.solid,
        borderWidth: 1,
        borderAlpha: 1,
      ),
      shadow: const ShadowRecipe(blur: 0, y: 0, alpha: 0),
    );
  }

  /// Kashi controls: 12px buttons and inputs, 10px chips and segments, 16px
  /// top bar and menus, 20px cards and nav, hairline borders, no shadow.
  static DesignLanguage get kashiLanguage {
    final base = paperLanguage;
    ControlRecipe r(
      ControlRecipe recipe,
      double radius, {
      FillKind? fill,
      double? border,
      double? borderAlpha,
      double? elevation,
    }) =>
        recipe.copyWith(
          shape: ShapeKind.rounded,
          radius: radius,
          fill: fill ?? recipe.fill,
          borderWidth: border ?? recipe.borderWidth,
          borderAlpha: borderAlpha ?? recipe.borderAlpha,
          elevation: elevation ?? recipe.elevation,
        );
    return base.copyWith(
      button: r(base.button, 12, border: 0, elevation: 0),
      chip: r(base.chip, 10, border: 1, borderAlpha: .35),
      input: r(base.input, 12, fill: FillKind.tonal, border: 0),
      card: r(base.card, 20, fill: FillKind.solid, border: 1, elevation: 0),
      sheet: r(base.sheet, 24, fill: FillKind.solid, border: 1),
      fab: r(base.fab, 16, fill: FillKind.solid, border: 0, elevation: 0),
      navPill: r(base.navPill, 20, fill: FillKind.solid, border: 1),
      dialog: r(base.dialog, 24, fill: FillKind.solid, border: 1),
      menu: r(base.menu, 16, fill: FillKind.solid, border: 1),
      chatBubble: r(base.chatBubble, 16),
      panelHeader: r(base.panelHeader, 16, fill: FillKind.solid, border: 1),
      listTile: r(base.listTile, 12, border: 0),
      tab: r(base.tab, 10),
      tooltip: r(base.tooltip, 8),
      shadow: const ShadowRecipe(blur: 0, y: 0, alpha: 0),
    );
  }

  static ThemePack get paper => ThemePack(
        meta: const ThemePackMeta(
          id: paperId,
          name: 'Paper',
          description:
              'Flat Material 3 Expressive. Warm paper, grey accent, hairline surfaces.',
          author: 'Aseman',
          previewColors: [
            Color(0xFFF6F1E8),
            Color(0xFF5E5E5E),
            Color(0xFFE4E4E4),
          ],
          builtin: true,
        ),
        language: paperLanguage,
        tokens: const ThemeTokenSet(
          light: ThemeTokens(
            accent: Color(0xFF5E5E5E),
            secondaryAccent: Color(0xFF5E5E5E),
            scaffold: Color(0xFFF6F1E8),
            surface: Color(0xFFFFFBF5),
            surfaceHigh: Color(0xFFF3EDE3),
            inputFill: Color(0xFFFFFBF5),
            cardAlpha: 1,
            overlayAlpha: 1,
            blurSigma: 0,
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
            titleWeight: 500,
            labelWeight: 500,
            letterSpacingDisplay: -0.25,
            letterSpacingTitle: 0,
            fabMistAlpha: 0,
          ),
          dark: ThemeTokens(
            accent: Color(0xFFE4E4E4),
            secondaryAccent: Color(0xFFE4E4E4),
            scaffold: Color(0xFF141210),
            surface: Color(0xFF1C1916),
            surfaceHigh: Color(0xFF26221E),
            inputFill: Color(0xFF26221E),
            cardAlpha: 1,
            overlayAlpha: 1,
            blurSigma: 0,
            success: Color(0xFF81C784),
            warning: Color(0xFFFFB74D),
            danger: Color(0xFFF2B8B5),
            titleWeight: 500,
            labelWeight: 500,
            letterSpacingDisplay: -0.25,
            letterSpacingTitle: 0,
            fabMistAlpha: 0,
          ),
        ),
        graphics: const ThemeGraphics(
          atmosphere: 'flat',
          haloStyle: 'solid',
          iconTreatment: 'rounded',
          backdropStyle: 'solid',
        ),
        shell: const ShellLayoutSpec(),
        // Grey stays first so [ThemePack.defaultPalette] is the paper default.
        // Ink and the Material 3 tone-40 primaries stay, then quieter colors
        // chosen to sit on warm paper.
        palettes: const [
          ThemePaletteOption(
            id: 'grey',
            label: 'Grey',
            accent: Color(0xFF5E5E5E),
            secondary: Color(0xFF5E5E5E),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'ink',
            label: 'Ink',
            accent: Color(0xFF4A433C),
            secondary: Color(0xFF4A433C),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'red',
            label: 'Red',
            accent: Color(0xFFB3251E),
            secondary: Color(0xFFB3251E),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'orange',
            label: 'Orange',
            accent: Color(0xFF9A4600),
            secondary: Color(0xFF9A4600),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'yellow',
            label: 'Yellow',
            accent: Color(0xFF8F4E06),
            secondary: Color(0xFF8F4E06),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'green',
            label: 'Green',
            accent: Color(0xFF006C35),
            secondary: Color(0xFF006C35),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'cyan',
            label: 'Cyan',
            accent: Color(0xFF00687C),
            secondary: Color(0xFF00687C),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'blue_variant',
            label: 'Blue variant',
            accent: Color(0xFF006788),
            secondary: Color(0xFF006788),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'blue',
            label: 'Blue',
            accent: Color(0xFF1157CE),
            secondary: Color(0xFF1157CE),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'purple',
            label: 'Purple',
            accent: Color(0xFF7438D2),
            secondary: Color(0xFF7438D2),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'baseline',
            label: 'Baseline',
            accent: Color(0xFF6750A4),
            secondary: Color(0xFF6750A4),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'pink',
            label: 'Pink',
            accent: Color(0xFFB60D6E),
            secondary: Color(0xFFB60D6E),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'grey_variant',
            label: 'Grey variant',
            accent: Color(0xFF5C5F5E),
            secondary: Color(0xFF5C5F5E),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'slate',
            label: 'Slate',
            accent: Color(0xFF4A5D6E),
            secondary: Color(0xFF4A5D6E),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'indigo',
            label: 'Indigo',
            accent: Color(0xFF3C4A86),
            secondary: Color(0xFF3C4A86),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'lagoon',
            label: 'Lagoon',
            accent: Color(0xFF1E655F),
            secondary: Color(0xFF1E655F),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'sage',
            label: 'Sage',
            accent: Color(0xFF5B6A45),
            secondary: Color(0xFF5B6A45),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'clay',
            label: 'Clay',
            accent: Color(0xFF8C4A38),
            secondary: Color(0xFF8C4A38),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'copper',
            label: 'Copper',
            accent: Color(0xFF8A5638),
            secondary: Color(0xFF8A5638),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'rose',
            label: 'Rose',
            accent: Color(0xFF96485A),
            secondary: Color(0xFF96485A),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
          ThemePaletteOption(
            id: 'plum',
            label: 'Plum',
            accent: Color(0xFF6D4B68),
            secondary: Color(0xFF6D4B68),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFB45309),
            danger: Color(0xFFB3261E),
          ),
        ],
      );


  /// Kashi accent options, named after Isfahan tilework. Each carries a lifted
  /// tone for the night-blue dark theme. Success, warning and danger stay on
  /// the pack's per-mode tokens (firoozeh, saffron, anar).
  static const kashiPalettes = <ThemePaletteOption>[
    ThemePaletteOption(
      id: 'lapis',
      label: 'Lapis',
      accent: Color(0xFF23409A),
      accentDark: Color(0xFF9DB0F2),
    ),
    ThemePaletteOption(
      id: 'firoozeh',
      label: 'Firoozeh',
      accent: Color(0xFF0B6B66),
      accentDark: Color(0xFF5CC6BE),
    ),
    ThemePaletteOption(
      id: 'saffron',
      label: 'Saffron',
      accent: Color(0xFF7E5000),
      accentDark: Color(0xFFF0B24A),
    ),
    ThemePaletteOption(
      id: 'anar',
      label: 'Anar',
      accent: Color(0xFFB0362C),
      accentDark: Color(0xFFF08A7E),
    ),
    ThemePaletteOption(
      id: 'ink',
      label: 'Ink',
      accent: Color(0xFF15171C),
      accentDark: Color(0xFFE7EBF5),
    ),
    ThemePaletteOption(
      id: 'kaghaz',
      label: 'Kaghaz',
      accent: Color(0xFF5A3E1B),
      accentDark: Color(0xFFD9B98A),
    ),
  ];

  /// Kashi: warm limestone paper in light, night blue in dark. Flat hairline
  /// surfaces, 20/16/12 corners, Vazirmatn type, colour reserved for meaning.
  static ThemePack get kashi => ThemePack(
        meta: const ThemePackMeta(
          id: kashiId,
          name: 'Kashi',
          description:
              'Isfahan tilework colours: lapis, firoozeh, saffron and anar on '
              'limestone paper, with a night-blue dark mode.',
          author: 'Aseman',
          previewColors: [
            Color(0xFFF4F1EA),
            Color(0xFF23409A),
            Color(0xFF0A1020),
          ],
          builtin: true,
        ),
        language: kashiLanguage,
        tokens: const ThemeTokenSet(
          light: ThemeTokens(
            accent: Color(0xFF23409A),
            secondaryAccent: Color(0xFF4A4E58),
            scaffold: Color(0xFFF4F1EA),
            surface: Color(0xFFFBFAF6),
            surfaceHigh: Color(0xFFECE8DE),
            inputFill: Color(0xFFECE8DE),
            cardAlpha: 1,
            overlayAlpha: 1,
            blurSigma: 0,
            radiusCard: 20,
            radiusInner: 16,
            radiusControl: 12,
            radiusFab: 16,
            radiusFabSmall: 12,
            radiusFabLarge: 20,
            success: Color(0xFF0B6B66),
            warning: Color(0xFF7E5000),
            danger: Color(0xFFB0362C),
            titleWeight: 800,
            labelWeight: 700,
            letterSpacingDisplay: -0.5,
            letterSpacingTitle: -0.2,
            fontFamily: kashiFont,
            fabMistAlpha: 0,
          ),
          dark: ThemeTokens(
            accent: Color(0xFF9DB0F2),
            secondaryAccent: Color(0xFFA7B1C8),
            scaffold: Color(0xFF0A1020),
            surface: Color(0xFF111A2F),
            surfaceHigh: Color(0xFF18233D),
            inputFill: Color(0xFF18233D),
            cardAlpha: 1,
            overlayAlpha: 1,
            blurSigma: 0,
            radiusCard: 20,
            radiusInner: 16,
            radiusControl: 12,
            radiusFab: 16,
            radiusFabSmall: 12,
            radiusFabLarge: 20,
            success: Color(0xFF5CC6BE),
            warning: Color(0xFFF0B24A),
            danger: Color(0xFFF08A7E),
            titleWeight: 800,
            labelWeight: 700,
            letterSpacingDisplay: -0.5,
            letterSpacingTitle: -0.2,
            fontFamily: kashiFont,
            fabMistAlpha: 0,
          ),
        ),
        graphics: const ThemeGraphics(
          atmosphere: 'flat',
          haloStyle: 'solid',
          iconTreatment: 'rounded',
          backdropStyle: 'solid',
        ),
        shell: const ShellLayoutSpec(),
        // Exact Kashi corners where the token defaults would round too much.
        components: const {
          // 12px on the 40px phone bar keeps the mockup's 16-on-56 proportion.
          'panel_header': ComponentStyle(radius: 12),
          'menu': ComponentStyle(radius: 16),
          'chip': ComponentStyle(radius: 10),
          'tab': ComponentStyle(radius: 10),
          'list_tile': ComponentStyle(radius: 12),
          'chat_bubble': ComponentStyle(radius: 16),
        },
        palettes: kashiPalettes,
      );

  /// UI family of the Kashi pack (Latin + Persian).
  static const kashiFont = 'Vazirmatn';

  /// Numbers, times, keys and dates.
  static const monoFont = 'IBMPlexMono';

  /// Adds the Kashi accents to another built-in pack's colour options so
  /// every theme offers them, without replacing that pack's own list.
  static ThemePack _withKashiAccents(ThemePack pack) {
    final own = pack.selectablePalettes;
    final ids = {for (final o in own) o.id};
    final extra = [
      for (final o in kashiPalettes.take(4))
        if (!ids.contains(o.id)) o,
    ];
    if (extra.isEmpty) return pack;
    return pack.copyWith(palettes: [...own, ...extra]);
  }

  static List<ThemePack> get all => [
        kashi,
        for (final p in [
          paper,
          sky,
          highContrast,
          compact,
          fluent,
          cupertino,
          neoBrutal,
        ])
          _withKashiAccents(p),
      ];

  static ThemePack byId(String id) {
    for (final pack in all) {
      if (pack.id == id) return pack;
    }
    return kashi;
  }
}
