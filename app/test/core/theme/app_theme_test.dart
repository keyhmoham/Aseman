import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/theme/app_surfaces.dart';
import 'package:aseman/src/core/theme/app_theme.dart';

void main() {
  for (final (name, theme) in [
    ('dark', AppTheme.darkWith(Colors.teal)),
    ('light', AppTheme.lightWith(Colors.teal)),
  ]) {
    test('$name theme gives every modal surface the same colour and scrim', () {
      final overlay = AppSurfaces.overlay(theme.colorScheme);
      expect(theme.dialogTheme.backgroundColor, overlay);
      expect(theme.bottomSheetTheme.backgroundColor, overlay);
      expect(theme.bottomSheetTheme.modalBackgroundColor, overlay);
      expect(theme.popupMenuTheme.color, overlay);
      expect(theme.menuTheme.style?.backgroundColor?.resolve({}), overlay);
      expect(theme.dropdownMenuTheme.menuStyle?.backgroundColor?.resolve({}),
          overlay);
      expect(theme.dialogTheme.barrierColor, AppSurfaces.barrier);
      expect(theme.bottomSheetTheme.modalBarrierColor, AppSurfaces.barrier);
      expect(theme.dialogTheme.shape, AppSurfaces.overlayShape);
      expect(theme.bottomSheetTheme.shape, AppSurfaces.sheetShape);
      expect(theme.cardTheme.color, AppSurfaces.card(theme.colorScheme));
    });
  }
}
