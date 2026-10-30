import 'package:aseman/src/core/theme/app_surfaces.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (name, theme) in [
    ('dark', AppTheme.darkWith(Colors.teal)),
    ('light', AppTheme.lightWith(Colors.teal)),
  ]) {
    test('$name theme gives every modal surface the same colour and scrim', () {
      final overlay = AppSurfaces.overlay(theme.colorScheme);
      expect(theme.dialogTheme.backgroundColor, overlay);
      // Sheets / drawers paint [GlassSurface] themselves; chrome stays clear.
      expect(theme.bottomSheetTheme.backgroundColor, Colors.transparent);
      expect(theme.bottomSheetTheme.modalBackgroundColor, Colors.transparent);
      expect(theme.drawerTheme.backgroundColor, Colors.transparent);
      expect(theme.drawerTheme.scrimColor, AppSurfaces.barrier);
      expect(theme.popupMenuTheme.color, overlay);
      expect(theme.menuTheme.style?.backgroundColor?.resolve({}), overlay);
      expect(
        theme.dropdownMenuTheme.menuStyle?.backgroundColor?.resolve({}),
        overlay,
      );
      expect(theme.dialogTheme.barrierColor, AppSurfaces.barrier);
      expect(theme.bottomSheetTheme.modalBarrierColor, AppSurfaces.barrier);
      expect(theme.dialogTheme.shape, AppSurfaces.overlayShape);
      expect(theme.bottomSheetTheme.shape, AppSurfaces.sheetShape);
      expect(theme.cardTheme.color, AppSurfaces.card(theme.colorScheme));
    });
  }

  test('glass panels read apart from the page in both themes', () {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final page = theme.scaffoldBackgroundColor;
      final panel = Color.alphaBlend(AppSurfaces.card(theme.colorScheme), page);
      final gap = [
        (panel.r - page.r).abs(),
        (panel.g - page.g).abs(),
        (panel.b - page.b).abs(),
      ].reduce((a, b) => a > b ? a : b);
      expect(
        gap,
        greaterThan(0.02),
        reason: '${theme.brightness.name} $panel vs $page',
      );
    }
  });

  test('light glass stays translucent', () {
    final scheme = AppTheme.light.colorScheme;
    expect(AppSurfaces.card(scheme).a, AppSurfaces.cardAlpha);
    expect(AppSurfaces.overlay(scheme).a, AppSurfaces.overlayAlpha);
    expect(AppSurfaces.card(scheme).a, lessThan(.75));
    expect(AppSurfaces.overlay(scheme).a, lessThan(.85));
  });
}
