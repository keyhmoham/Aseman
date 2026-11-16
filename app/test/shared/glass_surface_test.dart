import 'package:aseman/src/core/theme/app_surfaces.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/core/theme/aseman_tokens.dart';
import 'package:aseman/src/core/theme/default_theme_packs.dart';
import 'package:aseman/src/shared/widgets/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Color _fill(WidgetTester tester) => tester
    .widget<Material>(
      find.descendant(
        of: find.byType(GlassSurface),
        matching: find.byType(Material),
      ),
    )
    .color!;

void main() {
  testWidgets('an in-page card follows the pack card recipe: Sky keeps it '
      'quiet and opaque', (tester) async {
    final theme = AppTheme.fromPack(DefaultThemePacks.sky, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const GlassSurface(
          border: false,
          borderRadius: BorderRadius.zero,
          child: SizedBox(width: 120, height: 80),
        ),
      ),
    );
    expect(_fill(tester), theme.colorScheme.surface);
  });

  testWidgets('light modal glass stays translucent', (tester) async {
    final theme = AppTheme.fromPack(DefaultThemePacks.sky, Brightness.light);
    final tokens = theme.extension<AsemanTokens>()!;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const GlassSurface(
          alpha: AppSurfaces.overlayAlpha,
          border: false,
          child: SizedBox(width: 120, height: 80),
        ),
      ),
    );
    // Modal chrome follows the sheet recipe (glass) at the pack's opacity.
    expect(_fill(tester).a, tokens.overlayAlpha);
    expect(_fill(tester).a, lessThan(1));
  });
}
