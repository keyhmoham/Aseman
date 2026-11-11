import 'package:aseman/src/core/theme/app_surfaces.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/core/theme/aseman_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (name, theme) in [
    ('dark', AppTheme.darkWith(Colors.teal)),
    ('light', AppTheme.lightWith(Colors.teal)),
  ]) {
    test('$name theme gives every modal surface the same colour and scrim', () {
      // The pack's tokens set the overlay opacity (Sky: its own per mode).
      final tokens = theme.extension<AsemanTokens>();
      final overlay = AppSurfaces.overlay(theme.colorScheme, tokens: tokens);
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
      // In-page cards follow the pack's card recipe: Sky keeps them quiet,
      // a solid surface.
      expect(theme.cardTheme.color, theme.colorScheme.surface);
    });

    test('$name FABs use soft mist wash with a hairline rim', () {
      final scheme = theme.colorScheme;
      final fab = theme.floatingActionButtonTheme;
      expect(fab.backgroundColor, AppFab.mistOf(scheme));
      expect(fab.foregroundColor, AppFab.inkOf(scheme));
      expect(fab.elevation, 0);
      expect(fab.shape, isA<RoundedRectangleBorder>());
      expect(fab.enableFeedback, isTrue);
      expect(fab.extendedIconLabelSpacing, 10);
    });
  }

  test('AppFab shapes match Material 3 Expressive FAB radii', () {
    expect(AppFab.shape, isA<RoundedRectangleBorder>());
    expect(
      (AppFab.shape as RoundedRectangleBorder).borderRadius,
      const BorderRadius.all(Radius.circular(16)),
    );
    expect(
      (AppFab.smallShape as RoundedRectangleBorder).borderRadius,
      const BorderRadius.all(Radius.circular(12)),
    );
    expect(
      (AppFab.largeShape as RoundedRectangleBorder).borderRadius,
      const BorderRadius.all(Radius.circular(28)),
    );
  });

  testWidgets('AppFab reads the soft mist floatingActionButtonTheme',
      (tester) async {
    late Color bg;
    late Color fg;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightWith(Colors.teal),
        home: Builder(
          builder: (context) {
            bg = AppFab.backgroundOf(context);
            fg = AppFab.foregroundOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final scheme = AppTheme.lightWith(Colors.teal).colorScheme;
    expect(bg, AppFab.mistOf(scheme));
    expect(fg, AppFab.inkOf(scheme));
  });

  testWidgets('FloatingActionButton inherits soft mist shape and wash',
      (tester) async {
    final theme = AppTheme.lightWith(Colors.teal);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          floatingActionButton: FloatingActionButton(
            onPressed: null,
            child: Icon(Icons.add),
          ),
        ),
      ),
    );
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(FloatingActionButton),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.shape, isA<RoundedRectangleBorder>());
    expect(
      (material.shape! as RoundedRectangleBorder).borderRadius,
      const BorderRadius.all(Radius.circular(16)),
    );
    expect(material.color, AppFab.mistOf(theme.colorScheme));
  });

  testWidgets('SkyFab paints mist capsule with label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightWith(Colors.teal),
        home: Scaffold(
          floatingActionButton: SkyFab(
            onPressed: () {},
            icon: Icons.edit_rounded,
            label: 'Post',
          ),
        ),
      ),
    );
    expect(find.text('Post'), findsOneWidget);
    expect(find.byIcon(Icons.edit_rounded), findsOneWidget);
  });

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
    final theme = AppTheme.light;
    final tokens = theme.extension<AsemanTokens>()!;
    final scheme = theme.colorScheme;
    // The opacities are the pack's (Sky light: cards .96, modal chrome .88).
    expect(AppSurfaces.card(scheme, tokens: tokens).a, tokens.cardAlpha);
    expect(AppSurfaces.overlay(scheme, tokens: tokens).a, tokens.overlayAlpha);
    expect(tokens.cardAlpha, lessThan(1));
    // Modal chrome is more see-through than a card.
    expect(tokens.overlayAlpha, lessThan(tokens.cardAlpha));
  });
}
