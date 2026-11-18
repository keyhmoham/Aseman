import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/core/theme/default_theme_packs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pairs =
      <String, (Color Function(ColorScheme), Color Function(ColorScheme))>{
        'text on surface': _onSurface,
        'secondary text on surface': _variantOnSurface,
        'button label on primary': _onPrimary,
        'text on primary container': _onPrimaryContainer,
        'text on secondary container': _onSecondaryContainer,
        'text on error': _onError,
        'accent on surface': _accentOnSurface,
        'error on surface': _errorOnSurface,
      };

  for (final pack in DefaultThemePacks.all) {
    for (final dark in [false, true]) {
      test('${pack.meta.name} ${dark ? 'dark' : 'light'} text is readable', () {
        final palette = pack.defaultPalette;
        final theme = dark
            ? AppTheme.darkWith(
                palette.accent,
                pack: pack,
                paletteId: palette.id,
              )
            : AppTheme.lightWith(
                palette.accent,
                pack: pack,
                paletteId: palette.id,
              );
        final scheme = theme.colorScheme;
        // High contrast promises AAA for text; every other pack AA.
        final aaa = pack.id == DefaultThemePacks.contrastId;
        final failures = <String>[];
        for (final e in pairs.entries) {
          final fg = e.value.$1(scheme);
          final bg = e.value.$2(scheme);
          final ratio = AppTheme.contrastRatio(fg, bg);
          // Accents are controls and icons: 3:1 (AA), 7:1 for High contrast.
          final min =
              e.key.endsWith('on surface') &&
                  e.key.startsWith(RegExp('(accent|error)'))
              ? (aaa ? 7.0 : 3.0)
              : (aaa ? 7.0 : 4.5);
          if (ratio < min) {
            failures.add('${e.key}: ${ratio.toStringAsFixed(2)} (< $min)');
          }
        }
        expect(failures, isEmpty);
      });
    }
  }
}

Color _fgOnSurface(ColorScheme s) => s.onSurface;
Color _bgSurface(ColorScheme s) => s.surface;
const _onSurface = (_fgOnSurface, _bgSurface);
Color _fgVariant(ColorScheme s) => s.onSurfaceVariant;
const _variantOnSurface = (_fgVariant, _bgSurface);
Color _fgAccent(ColorScheme s) => s.primary;
const _accentOnSurface = (_fgAccent, _bgSurface);
Color _fgError(ColorScheme s) => s.error;
const _errorOnSurface = (_fgError, _bgSurface);
Color _fgOnPrimary(ColorScheme s) => s.onPrimary;
Color _bgPrimary(ColorScheme s) => s.primary;
const _onPrimary = (_fgOnPrimary, _bgPrimary);
Color _fgOnPc(ColorScheme s) => s.onPrimaryContainer;
Color _bgPc(ColorScheme s) => s.primaryContainer;
const _onPrimaryContainer = (_fgOnPc, _bgPc);
Color _fgOnSc(ColorScheme s) => s.onSecondaryContainer;
Color _bgSc(ColorScheme s) => s.secondaryContainer;
const _onSecondaryContainer = (_fgOnSc, _bgSc);
Color _fgOnErr(ColorScheme s) => s.onError;
Color _bgErr(ColorScheme s) => s.error;
const _onError = (_fgOnErr, _bgErr);
