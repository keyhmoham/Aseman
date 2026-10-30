import 'package:aseman/src/core/theme/app_surfaces.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/shared/widgets/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('light glass fill stays translucent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const GlassSurface(
          border: false,
          borderRadius: BorderRadius.zero,
          child: SizedBox(width: 120, height: 80),
        ),
      ),
    );

    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(GlassSurface),
        matching: find.byType(Material),
      ),
    );
    expect(material.color!.a, AppSurfaces.cardAlpha);
    expect(material.color!.a, lessThan(.75));
  });

  testWidgets('light modal glass stays translucent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const GlassSurface(
          alpha: AppSurfaces.overlayAlpha,
          border: false,
          child: SizedBox(width: 120, height: 80),
        ),
      ),
    );

    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(GlassSurface),
        matching: find.byType(Material),
      ),
    );
    expect(material.color!.a, AppSurfaces.overlayAlpha);
    expect(material.color!.a, lessThan(.85));
  });
}
