import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'design_language.dart';
import 'shell_layout.dart';
import 'theme_pack.dart';

/// Built-in packs shipped with the app (Sky default + design-language samples).
abstract final class DefaultThemePacks {
  static const skyId = 'builtin.sky';
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
        palettes: const [
          ThemePaletteOption(
            id: 'violet',
            label: 'Violet',
            accent: AppColors.primary,
            secondary: Color(0xFF6B7280),
            success: AppColors.success,
            warning: AppColors.warning,
            danger: AppColors.danger,
          ),
          ThemePaletteOption(
            id: 'blue',
            label: 'Blue',
            accent: Color(0xFF3B82F6),
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

  static List<ThemePack> get all =>
      [sky, highContrast, compact, fluent, cupertino, neoBrutal];

  static ThemePack byId(String id) {
    for (final pack in all) {
      if (pack.id == id) return pack;
    }
    return sky;
  }
}
