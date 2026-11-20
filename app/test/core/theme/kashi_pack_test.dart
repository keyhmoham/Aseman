import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/core/theme/default_theme_packs.dart';
import 'package:aseman/src/core/theme/theme_pack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Kashi is the default built-in pack', () {
    expect(DefaultThemePacks.all.first.id, DefaultThemePacks.kashiId);
    expect(DefaultThemePacks.byId('missing').id, DefaultThemePacks.kashiId);
    expect(DefaultThemePacks.kashi.defaultPalette.id, 'lapis');
  });

  test('Kashi surfaces are limestone in light and night blue in dark', () {
    final light = AppTheme.fromPack(DefaultThemePacks.kashi, Brightness.light);
    final dark = AppTheme.fromPack(DefaultThemePacks.kashi, Brightness.dark);
    expect(light.scaffoldBackgroundColor, const Color(0xFFF4F1EA));
    expect(light.colorScheme.surface, const Color(0xFFFBFAF6));
    expect(dark.scaffoldBackgroundColor, const Color(0xFF0A1020));
    expect(dark.colorScheme.surface, const Color(0xFF111A2F));
    expect(light.colorScheme.primary, const Color(0xFF23409A));
    expect(dark.colorScheme.primary, const Color(0xFF9DB0F2));
  });

  test('every Kashi accent reads on its surface in both modes', () {
    for (final option in DefaultThemePacks.kashiPalettes) {
      for (final b in Brightness.values) {
        final theme = AppTheme.fromPack(
          DefaultThemePacks.kashi,
          b,
          paletteId: option.id,
        );
        final s = theme.colorScheme;
        expect(
          AppTheme.contrastRatio(s.primary, s.surface),
          greaterThanOrEqualTo(4.5),
          reason: '${option.id} $b primary on surface',
        );
        expect(
          AppTheme.contrastRatio(s.onPrimary, s.primary),
          greaterThanOrEqualTo(4.5),
          reason: '${option.id} $b on-primary',
        );
        expect(
          AppTheme.contrastRatio(s.onSurfaceVariant, s.surface),
          greaterThanOrEqualTo(4.5),
          reason: '${option.id} $b secondary text',
        );
      }
    }
  });

  test('other built-in packs offer the Kashi accents too', () {
    for (final pack in DefaultThemePacks.all) {
      final ids = pack.selectablePalettes.map((o) => o.id).toSet();
      expect(
        ids.containsAll({'lapis', 'firoozeh', 'saffron', 'anar'}),
        isTrue,
        reason: pack.id,
      );
    }
  });

  test('palette dark accent survives JSON and applies in dark mode', () {
    const option = ThemePaletteOption(
      id: 'x',
      label: 'X',
      accent: Color(0xFF23409A),
      accentDark: Color(0xFF9DB0F2),
    );
    final back = ThemePaletteOption.fromJson(option.toJson());
    expect(back.accentDark, const Color(0xFF9DB0F2));
    expect(back.forBrightness(Brightness.dark).accent, const Color(0xFF9DB0F2));
    expect(back.forBrightness(Brightness.light).accent, const Color(0xFF23409A));
  });
}
