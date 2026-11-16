import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/features/desk/domain/desk_models.dart';
import 'package:aseman/src/features/desk/presentation/card_window.dart';
import 'package:aseman/src/features/search_feed/presentation/feed_canvas.dart';

import '../../fake_aseman_service.dart';

Finder windowChrome(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is WindowChromeButton && widget.tooltip == tooltip,
);

FeedPinSource heatmap() => const FeedPinSource(
  spaceId: FakeAsemanService.atlasId,
  spaceName: 'Atlas Collective',
  roomId: 'a1',
  roomName: 'general',
  pin: DeskPin(
    id: 'pin-heat',
    tool: 'tool-heat',
    kind: 'agui',
    name: 'Chart',
    title: 'Heatmap',
    frontend: 'agui',
  ),
);

Future<FeedCanvasController> pumpDesk(
  WidgetTester tester, {
  required bool mobile,
  Size size = const Size(1200, 800),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = FeedCanvasController(
    dependencies: AppDependencies.withService(FakeAsemanService()),
  );
  addTearDown(controller.dispose);
  controller.place(heatmap(), canvas: const Size(800, 600), asWidget: mobile);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: FeedCanvas(
          controller: controller,
          dependencies: controller.dependencies,
          mobile: mobile,
          bottomInset: mobile ? 96 : 0,
          onOpenSpace: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> flushSave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  testWidgets('the desk follows the account onto another device', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final service = FakeAsemanService();
    final first = FeedCanvasController(
      dependencies: AppDependencies.withService(service),
    );
    addTearDown(first.dispose);
    first.place(heatmap(), canvas: const Size(800, 600), asWidget: true);
    final moved = first.placements.single.rect.shift(const Offset(48, 32));
    first.move(first.placements.single.id, moved);
    await flushSave(tester);

    final second = FeedCanvasController(
      dependencies: AppDependencies.withService(service),
    );
    addTearDown(second.dispose);
    await tester.pump();
    await tester.pump();

    expect(second.placements, hasLength(1));
    final placed = second.placements.single;
    expect(placed.pin.title, 'Heatmap');
    expect(placed.widgetMode, isTrue);
    expect(placed.rect.left, moved.left.roundToDouble());
    expect(placed.rect.top, moved.top.roundToDouble());
    expect(placed.spaceName, 'Atlas Collective');
    expect(placed.minimized, isFalse);
  });

  testWidgets('a desk saved only on this device is stored on the account', (
    tester,
  ) async {
    final local = FeedPlacement(
      id: 'local-1',
      spaceId: FakeAsemanService.atlasId,
      spaceName: 'Atlas Collective',
      roomId: 'a1',
      roomName: 'general',
      pin: heatmap().pin,
      rect: const Rect.fromLTWH(80, 60, 280, 180),
      widgetMode: true,
    );
    SharedPreferences.setMockInitialValues({
      'aseman.feed.canvas.': jsonEncode({
        'placements': [local.toJson()],
      }),
    });
    final service = FakeAsemanService();
    final controller = FeedCanvasController(
      dependencies: AppDependencies.withService(service),
    );
    addTearDown(controller.dispose);
    await tester.pump();
    await tester.pump();
    expect(controller.placements.single.pin.title, 'Heatmap');
    expect(controller.placements.single.widgetMode, isTrue);

    await flushSave(tester);
    final restored = FeedCanvasController.placementsFromTree(
      await service.fetchMyMetadata(),
    );
    expect(restored, isNotNull);
    expect(restored!.single.id, 'local-1');
    expect(restored.single.rect.left, 80);
  });

  testWidgets('a placed window drags, swaps, minimizes and leaves the desk', (
    tester,
  ) async {
    await pumpDesk(tester, mobile: false);

    expect(find.text('Heatmap'), findsWidgets);
    expect(find.text('Empty AG-UI surface'), findsOneWidget);
    expect(windowChrome('Compact widget'), findsOneWidget);
    expect(windowChrome('Minimize'), findsOneWidget);
    expect(windowChrome('Maximize'), findsOneWidget);
    expect(windowChrome('Remove'), findsOneWidget);
    expect(find.byTooltip('Toolbox'), findsOneWidget);

    final before = tester.getTopLeft(find.byType(CardWindow));
    await tester.drag(find.text('Heatmap').first, const Offset(48, 36));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(find.byType(CardWindow));
    expect(after.dx, greaterThan(before.dx + 20));
    expect(after.dy, greaterThan(before.dy + 16));

    await tester.tap(windowChrome('Compact widget'));
    await tester.pumpAndSettle();
    expect(find.byType(CardWindow), findsNothing);
    expect(find.text('Empty AG-UI surface'), findsNothing);
    expect(find.byTooltip('App options'), findsOneWidget);

    final widgetBefore = tester.getTopLeft(find.text('Heatmap').first);
    await tester.drag(find.text('Heatmap').first, const Offset(30, 24));
    await tester.pumpAndSettle();
    final widgetAfter = tester.getTopLeft(find.text('Heatmap').first);
    expect(widgetAfter.dx, greaterThan(widgetBefore.dx + 10));
    expect(widgetAfter.dy, greaterThan(widgetBefore.dy + 10));

    await tester.tap(find.byTooltip('App options'));
    await tester.pumpAndSettle();
    expect(find.text('Window'), findsOneWidget);
    expect(find.text('Maximize'), findsOneWidget);
    expect(find.text('Minimize'), findsWidgets);
    expect(find.text('Remove'), findsWidgets);

    await tester.tap(find.text('Window'));
    await tester.pumpAndSettle();
    expect(find.byType(CardWindow), findsOneWidget);

    await tester.tap(windowChrome('Maximize'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CardWindow)).width, greaterThan(900));
    await tester.tap(windowChrome('Restore'));
    await tester.pumpAndSettle();

    await tester.tap(windowChrome('Minimize'));
    await tester.pumpAndSettle();
    expect(find.byType(CardWindow), findsNothing);

    await tester.tap(find.byTooltip('Heatmap · Atlas Collective · general'));
    await tester.pumpAndSettle();
    expect(find.byType(CardWindow), findsOneWidget);

    await tester.tap(windowChrome('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Your desk'), findsOneWidget);
    expect(find.text('Heatmap'), findsNothing);
  });

  testWidgets('a phone shows a compact widget that opens in a sheet', (
    tester,
  ) async {
    await pumpDesk(tester, mobile: true, size: const Size(390, 844));

    expect(find.byType(CardWindow), findsNothing);
    expect(windowChrome('Compact widget'), findsNothing);
    expect(windowChrome('Maximize'), findsNothing);
    expect(find.text('Heatmap'), findsWidgets);

    await tester.tap(find.byTooltip('App options'));
    await tester.pumpAndSettle();
    expect(find.text('Minimize'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(find.text('Window'), findsNothing);
    expect(find.text('Maximize'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Heatmap').first);
    await tester.pumpAndSettle();
    expect(find.text('Empty AG-UI surface'), findsOneWidget);
    expect(find.byTooltip('Minimize'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsOneWidget);
    expect(find.byTooltip('Maximize'), findsNothing);
    expect(find.byTooltip('Compact widget'), findsNothing);

    await tester.tap(find.byTooltip('Minimize'));
    await tester.pumpAndSettle();
    expect(find.text('Empty AG-UI surface'), findsNothing);
    expect(find.text('Heatmap'), findsNothing);
  });

  testWidgets('the toolbox scrim covers the screen past the desk', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = FeedCanvasController(
      dependencies: AppDependencies.withService(FakeAsemanService()),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(
                width: 280,
                child: ColoredBox(color: Color(0xFF112233)),
              ),
              Expanded(
                child: FeedCanvas(
                  controller: controller,
                  dependencies: controller.dependencies,
                  onOpenSpace: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Toolbox'));
    await tester.pumpAndSettle();

    const caption = 'Pinned windows from every space and room';
    expect(find.text(caption), findsOneWidget);
    final scrim = find.descendant(
      of: find.byType(FeedCanvas),
      matching: find.byType(ModalBarrier),
    );
    expect(scrim, findsOneWidget);
    expect(tester.getSize(scrim), const Size(1200, 800));
    expect(tester.getTopLeft(find.text(caption)).dx, greaterThan(280));

    await tester.tapAt(const Offset(24, 400));
    await tester.pumpAndSettle();
    expect(find.text(caption), findsNothing);
    expect(find.byTooltip('Toolbox'), findsOneWidget);
  });
}
