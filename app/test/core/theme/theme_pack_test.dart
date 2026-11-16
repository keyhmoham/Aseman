import 'dart:math' as math;

import 'package:aseman/src/core/theme/app_shape.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/core/theme/aseman_tokens.dart';
import 'package:aseman/src/core/theme/control_look.dart';
import 'package:aseman/src/core/theme/default_theme_packs.dart';
import 'package:aseman/src/core/theme/design_language.dart';
import 'package:aseman/src/core/theme/shell_layout.dart';
import 'package:aseman/src/core/theme/shell_layout.dart';
import 'package:aseman/src/core/theme/theme_chrome.dart';
import 'package:aseman/src/core/theme/theme_pack.dart';
import 'package:aseman/src/core/theme/theme_roles.dart';
import 'package:aseman/src/core/theme/theme_ui_spec.dart';
import 'package:aseman/src/shared/widgets/avatar.dart';
import 'package:aseman/src/shared/widgets/sky_ui.dart';
import 'package:aseman/src/shared/widgets/theme_slot_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sky pack round-trips JSON and validates', () {
    final pack = DefaultThemePacks.sky;
    expect(pack.validate(), isNull);
    final again = ThemePack.decode(pack.encode());
    expect(again.id, pack.id);
    expect(again.meta.name, 'Sky');
    expect(again.tokens.light.cardAlpha, pack.tokens.light.cardAlpha);
    expect(again.shell.home.phoneTabs, contains(FeatureSlots.homeChats));
    expect(again.language.id, DesignLanguage.materialExpressive);
    expect(again.palettes, isNotEmpty);
    expect(again.palettes.first.id, 'blue');
  });

  test('paper pack is flat material expressive without sky glow', () {
    final pack = DefaultThemePacks.paper;
    expect(pack.validate(), isNull);
    expect(pack.id, DefaultThemePacks.paperId);
    expect(
      DefaultThemePacks.all.map((p) => p.id),
      contains(DefaultThemePacks.paperId),
    );
    expect(DefaultThemePacks.byId(pack.id).meta.name, 'Paper');
    expect(pack.language.id, DesignLanguage.materialExpressive);
    expect(pack.language.button.shape, ShapeKind.stadium);
    expect(pack.language.chip.shape, ShapeKind.stadium);
    expect(pack.language.navPill.shape, ShapeKind.stadium);
    expect(pack.language.sheet.fill, FillKind.solid);
    expect(pack.language.dialog.fill, FillKind.solid);
    expect(pack.language.navPill.fill, FillKind.solid);
    expect(pack.language.card.elevation, 0);
    expect(pack.language.fab.elevation, lessThanOrEqualTo(1));
    expect(pack.language.shadow.alpha, 0);
    expect(pack.graphics.atmosphere, 'flat');
    expect(pack.tokens.light.blurSigma, 0);
    expect(pack.tokens.dark.blurSigma, 0);
    expect(pack.tokens.light.labelWeight, 500);
    expect(pack.tokens.light.scaffold, const Color(0xFFF6F1E8));
    expect(pack.defaultPalette.id, 'ink');
    expect(
      pack.palettes.map((p) => p.id),
      containsAll(<String>[
        'ink',
        'red',
        'orange',
        'yellow',
        'green',
        'cyan',
        'blue_variant',
        'blue',
        'purple',
        'baseline',
        'pink',
        'grey',
        'grey_variant',
      ]),
    );
    expect(pack.palettes.firstWhere((p) => p.id == 'baseline').accent,
        const Color(0xFF6750A4));
    expect(pack.palettes.firstWhere((p) => p.id == 'blue').accent,
        const Color(0xFF1157CE));
    expect(AppTheme.light.extension<AsemanTokens>()!.packId, pack.id);
    expect(DefaultThemePacks.byId('missing').id, pack.id);

    final blueDark = AppTheme.fromPack(
      pack,
      Brightness.dark,
      paletteId: 'blue',
    );
    expect(
      ThemeData.estimateBrightnessForColor(blueDark.colorScheme.primary),
      Brightness.light,
    );
    expect(blueDark.colorScheme.primary, isNot(pack.palettes.first.accent));

    final blue = AppTheme.fromPack(pack, Brightness.light, paletteId: 'blue');
    final roles = blue.colorScheme;
    expect(roles.secondary, isNot(roles.primary));
    expect(roles.primaryContainer, isNot(roles.primary));
    expect(roles.secondaryContainer, isNot(roles.primaryContainer));
    expect(roles.tertiary, isNot(roles.primary));
    expect(roles.surfaceContainer, isNot(roles.surface));
    expect(roles.surfaceTint, roles.primary);
    expect(roles.surface, isNot(light.colorScheme.surface));
    expect(roles.tertiary.b, greaterThan(roles.tertiary.r));
    expect(blue.chipTheme.selectedColor, roles.secondaryContainer);
    expect(blue.chipTheme.secondarySelectedColor, roles.secondaryContainer);
    expect(blue.cardTheme.color, roles.surfaceContainerHigh);
    expect(
      blue.inputDecorationTheme.fillColor,
      roles.surfaceContainerHighest,
    );
    expect(blue.extension<AsemanTokens>()!.cyan, roles.secondary);

    final again = ThemePack.decode(pack.encode());
    expect(again.language.sheet.fill, FillKind.solid);
    expect(again.graphics.atmosphere, 'flat');
    expect(again.tokens.light.blurSigma, 0);

    final light = AppTheme.fromPack(pack, Brightness.light);
    final dark = AppTheme.fromPack(pack, Brightness.dark);
    final lightTokens = light.extension<AsemanTokens>()!;
    expect(lightTokens.packId, DefaultThemePacks.paperId);
    expect(lightTokens.atmosphere, 'flat');
    expect(lightTokens.blurSigma, 0);
    expect(light.scaffoldBackgroundColor, light.colorScheme.surface);
    expect(light.colorScheme.surface, isNot(pack.tokens.light.scaffold));
    expect(
      light.navigationRailTheme.selectedLabelTextStyle?.fontWeight,
      FontWeight.w500,
    );
    expect(
      light.navigationBarTheme.labelTextStyle
          ?.resolve({WidgetState.selected})
          ?.fontWeight,
      FontWeight.w500,
    );
    expect(dark.colorScheme.primary, isNot(light.colorScheme.primary));
    expect(
      ThemeData.estimateBrightnessForColor(dark.colorScheme.primary),
      Brightness.light,
    );

    final sky = AppTheme.fromPack(DefaultThemePacks.sky, Brightness.light);
    expect(sky.extension<AsemanTokens>()!.atmosphere, 'mist');
    expect(sky.extension<AsemanTokens>()!.blurSigma, greaterThan(0));
  });

  testWidgets('paper backdrop skips the sky atmosphere wash', (tester) async {
    Future<bool> wash(ThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(theme.extension<AsemanTokens>()!.packId),
          theme: theme,
          home: const SkyBackdrop(child: Text('page')),
        ),
      );
      return tester.widgetList<CustomPaint>(find.byType(CustomPaint)).any(
            (paint) => paint.painter is SkyAtmospherePainter,
          );
    }

    expect(
      await wash(AppTheme.fromPack(DefaultThemePacks.paper, Brightness.light)),
      isFalse,
    );
    expect(
      await wash(AppTheme.fromPack(DefaultThemePacks.sky, Brightness.light)),
      isTrue,
    );
  });

  test('each builtin pack proposes dedicated palette options', () {
    for (final pack in DefaultThemePacks.all) {
      expect(pack.selectablePalettes, isNotEmpty, reason: pack.id);
      expect(pack.defaultPalette.accent, isNot(equals(Colors.transparent)));
    }
  });

  test('palette overlay unifies accent secondary and status colors', () {
    final pack = DefaultThemePacks.sky;
    final rose = pack.resolvePalette(paletteId: 'rose');
    final theme = AppTheme.fromPack(
      pack,
      Brightness.light,
      paletteId: rose.id,
    );
    final tokens = theme.extension<AsemanTokens>()!;
    expect(theme.colorScheme.primary, rose.accent);
    // Unified packs fold decorative secondary/cyan into the brand accent.
    expect(tokens.cyan, rose.accent);
    expect(theme.colorScheme.secondary, rose.accent);
    expect(tokens.success, rose.success);
  });

  testWidgets('SoftCard stays neutral even when an accent is passed',
      (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.sky,
      Brightness.light,
      paletteId: 'rose',
    );
    late Color fill;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            fill = ThemeChrome.cardFillColor(
              context,
              accent: const Color(0xFFE11D48),
            );
            return SoftCard(
              accent: const Color(0xFFE11D48),
              child: const Text('post'),
            );
          },
        ),
      ),
    );
    expect(fill, theme.colorScheme.surface);
    expect(theme.colorScheme.surfaceTint, Colors.transparent);
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(SoftCard),
        matching: find.byType(Material),
      ).first,
    );
    expect(material.color, theme.colorScheme.surface);
  });

  test('design language presets reshape control recipes', () {
    final fluent = DesignLanguage.presetOf(DesignLanguage.fluent);
    expect(fluent.button.radius, 4);
    expect(fluent.interaction.ink, InkKind.highlight);

    final neo = DesignLanguage.presetOf(DesignLanguage.neoBrutal);
    expect(neo.card.shape, ShapeKind.sharp);
    expect(neo.card.borderWidth, 2);
    expect(neo.shadow.hard, isTrue);

    final cupertino = DesignLanguage.presetOf(DesignLanguage.cupertino);
    expect(cupertino.fab.shape, ShapeKind.stadium);
  });

  test('neo-brutal pack applies sharp button shapes in ThemeData', () {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.neoBrutal,
      Brightness.light,
    );
    final tokens = theme.extension<AsemanTokens>()!;
    expect(tokens.language.id, DesignLanguage.neoBrutal);
    final shape = theme.filledButtonTheme.style?.shape?.resolve({});
    expect(shape, isA<RoundedRectangleBorder>());
    expect(
      (shape as RoundedRectangleBorder).borderRadius,
      BorderRadius.zero,
    );
  });

  testWidgets('SoftCard uses pack card shape not Material RRect', (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.neoBrutal,
      Brightness.light,
    );
    late OutlinedBorder shape;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            shape = ThemeChrome.cardShape(context);
            return SoftCard(
              onTap: () {},
              child: const Text('card'),
            );
          },
        ),
      ),
    );
    expect(shape, isA<RoundedRectangleBorder>());
    expect(
      (shape as RoundedRectangleBorder).borderRadius,
      BorderRadius.zero,
    );
    expect(
      (shape as RoundedRectangleBorder).side.width,
      greaterThanOrEqualTo(2),
    );
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(SoftCard),
        matching: find.byType(Material),
      ).first,
    );
    expect(material.shape, isA<RoundedRectangleBorder>());
    expect(
      (material.shape as RoundedRectangleBorder).borderRadius,
      BorderRadius.zero,
    );
  });

  test('fluent and cupertino languages diverge from Material expressive', () {
    final material = DesignLanguage.presetOf(DesignLanguage.materialExpressive);
    final fluent = DesignLanguage.presetOf(DesignLanguage.fluent);
    final cupertino = DesignLanguage.presetOf(DesignLanguage.cupertino);
    expect(fluent.button.radius, isNot(material.button.radius));
    expect(fluent.interaction.ink, InkKind.highlight);
    expect(fluent.card.fill, FillKind.solid);
    expect(cupertino.fab.shape, ShapeKind.stadium);
    expect(cupertino.interaction.pressScale, lessThan(1));
    expect(DefaultThemePacks.fluent.language.card.borderWidth, greaterThan(0));
  });

  test('toggle and slider recipes theme Switch Checkbox and Slider', () {
    final neo = AppTheme.fromPack(
      DefaultThemePacks.neoBrutal,
      Brightness.light,
    );
    expect(neo.switchTheme.splashRadius, 0);
    expect(neo.checkboxTheme.shape, isA<RoundedRectangleBorder>());
    expect(
      (neo.checkboxTheme.shape as RoundedRectangleBorder).borderRadius,
      BorderRadius.zero,
    );
    expect(neo.sliderTheme.trackShape, isA<RectangularSliderTrackShape>());
    expect(
      DefaultThemePacks.neoBrutal.language.toggle.shape,
      ShapeKind.sharp,
    );

    final fluent = AppTheme.fromPack(
      DefaultThemePacks.fluent,
      Brightness.light,
    );
    expect(fluent.switchTheme.splashRadius, isNull);
    expect(fluent.sliderTheme.trackShape, isA<RoundedRectSliderTrackShape>());
  });

  test('rich control recipes round-trip effects motion and states', () {
    final rich = ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.gradient,
      radius: 12,
      gradient: const GradientSpec(
        stops: [
          GradientStopSpec(color: Color(0xFF8B7BFF), stop: 0),
          GradientStopSpec(color: Color(0xFF58D7FF), stop: 1),
        ],
      ),
      effects: const ControlEffects(glow: 12, sheen: 0.2, opacity: 0.95),
      motion: const ControlMotion(pressScale: 0.96, hoverLift: 2, durationMs: 140),
      typography: const ControlTypography(weight: 700, size: 13),
      states: const ControlStates(
        pressed: ControlStateStyle(scale: 0.94, glow: 4),
        hovered: ControlStateStyle(elevation: 3),
      ),
    );
    final again = ControlRecipe.fromJson(rich.toJson());
    expect(again.fill, FillKind.gradient);
    expect(again.effects.glow, 12);
    expect(again.motion.pressScale, 0.96);
    expect(again.states.pressed.scale, 0.94);
    expect(again.gradient!.stops, hasLength(2));
  });

  test('ThemeChrome.look resolves pack graphical behaviour', () {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.fluent,
      Brightness.light,
    );
    late ControlLook look;
    // Resolve without a tree via tokens on the theme extension path:
    final tokens = theme.extension<AsemanTokens>()!;
    final recipe = tokens.control('button');
    expect(recipe.motion.pressScale, lessThan(1));
    expect(recipe.states.hovered.elevation, isNotNull);
    expect(tokens.language.recipeFor('avatar').shape, isNotNull);
    expect(tokens.language.recipeFor('badge').shape, ShapeKind.stadium);
    look = ControlLook(
      slot: 'button',
      recipe: recipe,
      shape: recipe.border(),
      fill: theme.colorScheme.primary,
      padding: EdgeInsets.symmetric(
        horizontal: recipe.paddingH,
        vertical: recipe.paddingV,
      ),
      ink: recipe.ink,
      motion: recipe.motion,
      effects: recipe.effects,
    );
    expect(look.motion.hoverLift, greaterThan(0));
  });

  testWidgets('PackSwitch paints sharp control for neo-brutal', (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.neoBrutal,
      Brightness.light,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: PackSwitch(value: true, onChanged: (_) {}),
        ),
      ),
    );
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(PackSwitch), findsOneWidget);
    await tester.tap(find.byType(PackSwitch));
    await tester.pump();
  });

  test('fluent pack uses compact control height', () {
    final theme =
        AppTheme.fromPack(DefaultThemePacks.fluent, Brightness.light);
    final tokens = theme.extension<AsemanTokens>()!;
    expect(tokens.language.controlHeight, 32);
    expect(tokens.control('button').radius, 4);
  });

  test('component override merges onto language recipe', () {
    final lang = DesignLanguage.presetOf(DesignLanguage.materialExpressive);
    final resolved = lang.resolve(
      'button',
      const ComponentStyle(radius: 6, shapeKind: ShapeKind.sharp),
    );
    expect(resolved.radius, 6);
    expect(resolved.shape, ShapeKind.sharp);
    expect(resolved.fill, lang.button.fill);
  });

  test('unknown schema is rejected', () {
    expect(
      () => ThemePack.fromJson({
        'schema': 'other/v1',
        'meta': {'id': 'x', 'name': 'X'},
        'tokens': {'light': {}, 'dark': {}},
      }),
      throwsFormatException,
    );
  });

  test('compact pack reorders store and home tabs', () {
    final pack = DefaultThemePacks.compact;
    expect(pack.shell.home.resolvedPhoneTabs.first, FeatureSlots.homeExplore);
    expect(pack.shell.store.resolvedTabs.first, FeatureSlots.storeThemes);
  });

  test('AppTheme.fromPack registers AsemanTokens extension', () {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.highContrast,
      Brightness.light,
    );
    final tokens = theme.extension<AsemanTokens>();
    expect(tokens, isNotNull);
    expect(tokens!.packId, DefaultThemePacks.contrastId);
    expect(tokens.blurSigma, 0);
    expect(tokens.cardAlpha, 1);
    expect(tokens.radiusCard, 12);
    expect(theme.colorScheme.surfaceTint, Colors.transparent);
  });

  test('accent overlay keeps pack radii', () {
    final theme = AppTheme.lightWith(
      Colors.teal,
      pack: DefaultThemePacks.compact,
    );
    final tokens = theme.extension<AsemanTokens>()!;
    expect(tokens.radiusCard, 16);
    expect(theme.colorScheme.primary, isNot(equals(Colors.transparent)));
  });

  test('neo-brutal pack reshapes icon buttons, chips, and nav indicator', () {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.neoBrutal,
      Brightness.light,
    );
    final tokens = theme.extension<AsemanTokens>()!;
    expect(tokens.control('button').shape, ShapeKind.sharp);
    final iconShape = theme.iconButtonTheme.style?.shape?.resolve({});
    expect(iconShape, isA<RoundedRectangleBorder>());
    expect(
      (iconShape as RoundedRectangleBorder).borderRadius,
      BorderRadius.zero,
    );
    expect(theme.chipTheme.shape, isA<RoundedRectangleBorder>());
    expect(
      (theme.chipTheme.shape as RoundedRectangleBorder).borderRadius,
      BorderRadius.zero,
    );
    expect(theme.navigationBarTheme.indicatorShape, isA<RoundedRectangleBorder>());
    expect(theme.badgeTheme.backgroundColor, tokens.danger);
  });

  testWidgets('input shell and chat bubbles follow pack recipes', (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.fluent,
      Brightness.light,
    );
    final tokens = theme.extension<AsemanTokens>()!;
    late BorderRadius inputRadius;
    late BorderRadius bubbleRadius;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            inputRadius = ThemeChrome.inputShell(context).radius;
            bubbleRadius = ThemeChrome.chatBubble(
              context,
              mine: true,
            ).borderRadius as BorderRadius;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(inputRadius, tokens.control('input').borderRadius);
    expect(bubbleRadius.topRight,
        Radius.circular(math.max(4.0, tokens.control('chat_bubble').radius * .3)));
  });

  test('pack token radii reshape buttons, bubbles, and panel headers', () {
    final contrast = AppTheme.fromPack(
      DefaultThemePacks.highContrast,
      Brightness.light,
    ).extension<AsemanTokens>()!;
    expect(contrast.control('button').radius, contrast.radiusControl);
    expect(contrast.control('chat_bubble').radius, contrast.radiusInner);
    expect(contrast.control('panel_header').radius, contrast.radiusCard);
    expect(contrast.control('fab').radius, contrast.radiusFab);

    final neo = AppTheme.fromPack(
      DefaultThemePacks.neoBrutal,
      Brightness.light,
    ).extension<AsemanTokens>()!;
    expect(neo.control('chat_bubble').shape, ShapeKind.sharp);
    expect(neo.control('panel_header').shape, ShapeKind.sharp);
    expect(neo.control('chat_bubble').radius, 0);
    expect(neo.control('button').radius, 0);
  });

  testWidgets('SoftCard corners follow pack even with literal radii',
      (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.highContrast,
      Brightness.light,
    );
    final tokens = theme.extension<AsemanTokens>()!;
    late BorderRadius fromLiteral;
    late BorderRadius fromInset;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            fromLiteral = ThemeChrome.softCardCorners(context, 22);
            fromInset = ThemeChrome.softCardCorners(context, AppShape.card - 2);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(fromLiteral, tokens.control('card').borderRadius);
    expect(fromInset, tokens.control('card').borderRadius);
    expect(fromLiteral, BorderRadius.circular(tokens.radiusCard));
  });

  testWidgets('neo-brutal SoftCard corners stay sharp', (tester) async {
    late BorderRadius neoCorners;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromPack(DefaultThemePacks.neoBrutal, Brightness.light),
        home: Builder(
          builder: (context) {
            neoCorners = ThemeChrome.softCardCorners(context, 24);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(neoCorners, BorderRadius.zero);
  });

  testWidgets('AppShape.resolve remaps sentinels, offsets, and Sky literals',
      (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.highContrast,
      Brightness.light,
    );
    final tokens = theme.extension<AsemanTokens>()!;
    late double card;
    late double cardMinus2;
    late double literal28;
    late double custom;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            card = AppShape.resolve(context, AppShape.card);
            cardMinus2 = AppShape.resolve(context, AppShape.card - 2);
            literal28 = AppShape.resolve(context, 28);
            custom = AppShape.resolve(context, 9);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(card, tokens.radiusCard);
    expect(cardMinus2, tokens.radiusCard - 2);
    expect(literal28, tokens.radiusCard);
    expect(custom, 9);
  });

  testWidgets('avatar faces follow pack control radius with the halo',
      (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.fluent,
      Brightness.light,
    );
    late BorderRadius corners;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            corners = context.avatarBorderRadius(40);
            return AppAvatar('AB', color: theme.colorScheme.primary, radius: 20);
          },
        ),
      ),
    );
    expect(corners.topLeft.x, lessThan(19));
    expect(find.byType(CircleAvatar), findsNothing);
    expect(find.byType(AppAvatar), findsOneWidget);
  });

  testWidgets('neo-brutal avatars stay sharp not circular', (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.neoBrutal,
      Brightness.light,
    );
    late BorderRadius corners;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            corners = context.avatarBorderRadius(48);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(corners, BorderRadius.zero);
  });

  testWidgets('ThemeRoles follow the selected pack palette', (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.sky,
      Brightness.light,
      paletteId: 'rose',
    );
    final tokens = theme.extension<AsemanTokens>()!;
    late Color success;
    late Color danger;
    late Color selected;
    late Color bubble;
    late Color well;
    late List<Color> pool;
    late Color identity;
    late Color identityAgain;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            success = ThemeRoles.status(context, 'online');
            danger = ThemeRoles.status(context, 'failed');
            selected = ThemeRoles.selectedFill(context);
            bubble = ThemeRoles.bubbleFill(context);
            well = ThemeRoles.wellFill(context);
            pool = ThemeRoles.identityPool(context);
            identity = ThemeRoles.identity(context, 'agent-42');
            identityAgain = ThemeRoles.identity(context, 'agent-42');
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(success, tokens.success);
    expect(danger, tokens.danger);
    expect(pool, isNotEmpty);
    expect(pool.first, theme.colorScheme.primary);
    expect(pool, contains(identity));
    expect(identity, identityAgain);
    // Quiet fills — not solid Material container washes.
    expect(selected, isNot(equals(theme.colorScheme.primaryContainer)));
    expect(bubble, isNot(equals(theme.colorScheme.primaryContainer)));
    expect(well, theme.colorScheme.surfaceContainerHighest);
  });

  test('parts colours round-trip in pack JSON', () {
    final pack = DefaultThemePacks.sky.copyWith(
      parts: ThemePartColors(
        unified: false,
        overrides: {
          ThemePartId.nav: const ThemePartColor(accent: Color(0xFF4F46E5)),
          ThemePartId.desk: const ThemePartColor(
            accent: Color(0xFF0D9488),
            secondary: Color(0xFF14B8A6),
          ),
        },
      ),
    );
    expect(pack.validate(), isNull);
    final again = ThemePack.decode(pack.encode());
    expect(again.parts.unified, isFalse);
    expect(again.parts.overrides[ThemePartId.nav]?.accent,
        const Color(0xFF4F46E5));
    expect(again.parts.overrides[ThemePartId.desk]?.secondary,
        const Color(0xFF14B8A6));
  });

  testWidgets('unified accent collapses secondary cyan and identity',
      (tester) async {
    final theme = AppTheme.fromPack(
      DefaultThemePacks.sky,
      Brightness.light,
      paletteId: 'rose',
    );
    final tokens = theme.extension<AsemanTokens>()!;
    expect(tokens.unifiedAccent, isTrue);
    expect(theme.colorScheme.secondary, theme.colorScheme.primary);
    expect(tokens.cyan, theme.colorScheme.primary);
    late Color identity;
    late Color nav;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            identity = ThemeRoles.identity(context, 'anyone');
            nav = ThemeRoles.partAccent(context, ThemePartId.nav);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(identity, theme.colorScheme.primary);
    expect(nav, theme.colorScheme.primary);
  });

  test('theme ui disabled slots and elpian surfaces round-trip', () {
    final pack = DefaultThemePacks.sky.copyWith(
      ui: ThemeUiSpec(
        disabled: const {
          FeatureSlots.settingsAdvanced,
          ThemeChromeSlots.feedAssistant,
        },
        surfaces: {
          FeatureSlots.homeYou: ThemeSurfaceSpec(
            slot: FeatureSlots.homeYou,
            mode: ThemeSurfaceMode.after,
            elpian: ThemeElpianSource(
              inline: {
                'type': 'Text',
                'props': {'text': 'Hello theme', 'className': 'primary'},
              },
            ),
          ),
        },
        islands: {
          'island.pulse': ThemeIslandSpec(
            id: 'island.pulse',
            title: 'Pulse',
            placement: ThemeIslandPlacement.homeTab,
            elpian: ThemeElpianSource(
              code: 'askHost("render", JSON.stringify({type:"Text",props:{text:"hi"}}));',
            ),
          ),
        },
      ),
    );
    expect(pack.validate(), isNull);
    final again = ThemePack.decode(pack.encode());
    expect(again.ui.disabled, contains(FeatureSlots.settingsAdvanced));
    expect(again.ui.disabled, contains(ThemeChromeSlots.feedAssistant));
    final surface = again.ui.surfaceFor(FeatureSlots.homeYou);
    expect(surface?.mode, ThemeSurfaceMode.after);
    expect(surface?.elpian.hasInline, isTrue);
    final island = again.ui.islandFor('island.pulse');
    expect(island?.placement, ThemeIslandPlacement.homeTab);
    expect(island?.elpian.hasProgram, isTrue);
  });

  testWidgets('ThemeSlotHost hides disabled slots', (tester) async {
    final pack = DefaultThemePacks.sky.copyWith(
      ui: const ThemeUiSpec(disabled: {FeatureSlots.homeComposer}),
    );
    final theme = AppTheme.fromPack(pack, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) => ThemeSlotHost(
            slot: FeatureSlots.homeComposer,
            child: const Text('composer'),
          ),
        ),
      ),
    );
    expect(find.text('composer'), findsNothing);
  });

  test('chrome aliases disable the matching feature slot', () {
    const ui = ThemeUiSpec(disabled: {ThemeChromeSlots.feedComposer});
    expect(ui.isDisabled(FeatureSlots.homeComposer), isTrue);
    expect(ui.isDisabled(ThemeChromeSlots.feedComposer), isTrue);
  });

  testWidgets('ThemeSlotHost wrap injects ThemeHostChild', (tester) async {
    final pack = DefaultThemePacks.sky.copyWith(
      ui: ThemeUiSpec(
        surfaces: {
          FeatureSlots.homeYou: ThemeSurfaceSpec(
            slot: FeatureSlots.homeYou,
            mode: ThemeSurfaceMode.wrap,
            elpian: ThemeElpianSource(
              inline: {
                'type': 'Column',
                'children': [
                  {
                    'type': 'Text',
                    'props': {'text': 'theme-chrome', 'className': 'primary'},
                  },
                  {'type': 'ThemeHostChild'},
                ],
              },
            ),
          ),
        },
      ),
    );
    final theme = AppTheme.fromPack(pack, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) => ThemeSlotHost(
            slot: FeatureSlots.homeYou,
            child: const Text('built-in-you'),
          ),
        ),
      ),
    );
    // The Elpian panel is a deferred library: it shows once it has loaded.
    await tester.pumpAndSettle();
    expect(find.text('theme-chrome'), findsOneWidget);
    expect(find.text('built-in-you'), findsOneWidget);
  });

  testWidgets('part accent overrides apply when not unified', (tester) async {
    const navAccent = Color(0xFF4F46E5);
    final pack = DefaultThemePacks.sky.copyWith(
      parts: const ThemePartColors(
        unified: false,
        overrides: {
          ThemePartId.nav: ThemePartColor(accent: navAccent),
        },
      ),
    );
    final theme = AppTheme.fromPack(pack, Brightness.light, paletteId: 'violet');
    late Color nav;
    late Color feed;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            nav = ThemeRoles.partAccent(context, ThemePartId.nav);
            feed = ThemeRoles.partAccent(context, ThemePartId.feed);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(nav, navAccent);
    expect(feed, theme.colorScheme.primary);
    expect(nav, isNot(equals(feed)));
  });
}
