import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/features/market/presentation/bots_store_screen.dart';
import 'package:aseman/src/features/market/presentation/market_screen.dart';

import '../../fake_aseman_service.dart';

void main() {
  testWidgets('agents and apps both offer add to', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketScreen(
            dependencies: AppDependencies.withService(FakeAsemanService()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a');
    await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
    await tester.pumpAndSettle();

    expect(find.text('AlphaBot'), findsWidgets);
    expect(find.text('Add to'), findsOneWidget);

    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();

    expect(find.text('Chart Studio'), findsWidgets);
    expect(find.text('Add to'), findsOneWidget);
  });

  testWidgets('browse layout fits phone and desktop', (tester) async {
    final service = _CatalogService();
    final deps = AppDependencies.withService(service);
    for (final size in [const Size(390, 844), const Size(1200, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BotsStoreScreen(dependencies: deps, fullPage: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Decillion Store'), findsOneWidget);
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();
      expect(find.text('FEATURED'), findsOneWidget);
      expect(find.text('Top charts'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Themes'));
      await tester.pumpAndSettle();
      expect(find.text('Included with Decillion'), findsOneWidget);
      // The shelf leads with the default pack.
      expect(find.text('Kashi'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('catalog rows fit a phone', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketScreen(
            dependencies: AppDependencies.withService(_CatalogService()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.vertical,
      ),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    expect(find.text('Add to'), findsWidgets);
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    expect(find.text('Studio 0'), findsOneWidget);
    expect(find.text('Add to'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add to lets you pick a workspace or a direct chat', (
    tester,
  ) async {
    final service = _CatalogService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketScreen(
            dependencies: AppDependencies.withService(service),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add to').first);
    await tester.pumpAndSettle();

    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('Atlas Collective'), findsOneWidget);
    expect(find.text('Direct chats'), findsOneWidget);
    expect(find.text('Maya Chen'), findsOneWidget);

    await tester.tap(find.text('Atlas Collective'));
    await tester.pumpAndSettle();

    expect(service.installs, [('agent-0', FakeAsemanService.atlasId)]);
    expect(
      find.text('Field Agent 0 added to Atlas Collective'),
      findsOneWidget,
    );
  });
}

class _CatalogService extends FakeAsemanService {
  @override
  Future<List<MarketListing>> fetchMarket({
    String? type,
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    final all = <MarketListing>[
      for (var i = 0; i < 12; i++)
        MarketListing(
          id: 'agent-$i',
          publisherId: 'p',
          botId: 'bot-$i',
          type: 'agent',
          name: 'Field Agent $i',
          description:
              'Keeps a running brief and coordinates work across the room.',
          category: i.isEven ? 'Productivity' : 'Research',
          installs: 40 + i * 12,
          price: i == 0 ? 0 : 80,
        ),
      for (var i = 0; i < 4; i++)
        MarketListing(
          id: 'app-$i',
          publisherId: 'p',
          botId: 'tool-$i',
          type: 'tool',
          name: 'Studio $i',
          description: 'A small app for the workspace.',
          category: 'Apps',
          installs: 10 + i,
        ),
      MarketListing(
        id: 'theme-1',
        publisherId: 'p',
        botId: 'theme-bot',
        type: 'theme',
        name: 'Dusk Glass',
        description: 'A quiet dark glass pack.',
        price: 0,
      ),
    ];
    final q = (query ?? '').toLowerCase();
    return [
      for (final listing in all)
        if ((type == null || type.isEmpty || listing.type == type) &&
            (q.isEmpty || listing.name.toLowerCase().contains(q)))
          listing,
    ].skip(offset).take(limit).toList();
  }
}
