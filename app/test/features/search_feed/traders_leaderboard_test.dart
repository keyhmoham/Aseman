import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/core/network/session_store.dart';
import 'package:tradera/src/features/search_feed/domain/trader.dart';
import 'package:tradera/src/features/search_feed/presentation/search_feed_view_model.dart';
import 'package:tradera/src/features/search_feed/presentation/traders_leaderboard.dart';

import '../../fake_tradera_service.dart';

class _NoEvaluator extends FakeTraderaService {
  @override
  Future<Map<String, dynamic>> fetchTraderLeaderboard(
          {String board = 'overall', int limit = 100}) async =>
      throw const ApiException(
          'NOT_FOUND', 'the admins space has no evaluator tool',
          status: 404);
}

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .clearAllTestValues();
  });

  test('parses the evaluator leaderboard and report', () async {
    final fake = FakeTraderaService();
    final model =
        SearchFeedViewModel(dependencies: AppDependencies.withService(fake));
    await model.loadTraders();
    expect(model.tradersError, isNull);
    expect(model.traders.map((t) => t.handle),
        ['daniel_crypto365', 'vlad_anderson', 'newcomer']);
    expect(model.tradersTotal, 3);
    expect(model.tradersEvaluated, 2);
    final top = model.traders.first;
    expect(top.scores.overall, 84.5);
    expect(top.scores.of(TraderBoard.fundamental), 88);
    expect(top.rank, 1);
    expect(top.followers, 10975);
    expect(model.traders.last.evaluated, isFalse);

    await model.setBoard(TraderBoard.technical);
    expect(fake.boardsAsked.last, 'technical');
    expect(model.traders.first.handle, 'vlad_anderson');

    model.setQuery('average');
    expect(model.searchTraders(model.traders).single.handle, 'vlad_anderson');

    final report = await model.traderReport('daniel_crypto365');
    expect(report!.strengths, ['Clear invalidation levels']);
    expect(report.history.length, 2);
    expect(report.sections.keys, ['Technical analysis']);
    expect(report.sections['Technical analysis']!.first.key, 'Trend analysis');
  });

  test('explains a missing evaluator', () async {
    final model = SearchFeedViewModel(
        dependencies: AppDependencies.withService(_NoEvaluator()));
    await model.loadTraders();
    expect(model.traders, isEmpty);
    expect(model.tradersError, contains('not set up yet'));
  });

  testWidgets('the Traders tab ranks, switches boards and opens a report',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    final fake = FakeTraderaService();
    final model =
        SearchFeedViewModel(dependencies: AppDependencies.withService(fake));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: model,
                builder: (context, _) => CustomScrollView(
                    slivers: traderLeaderboardSlivers(context, model, 16))))));
    await model.loadTraders();
    await tester.pumpAndSettle();

    expect(find.text('Traders leaderboard'), findsOneWidget);
    expect(find.textContaining('2 of 3 evaluated'), findsOneWidget);
    expect(find.text('Daniel Markson'), findsOneWidget);
    expect(find.text('84.5'), findsWidgets);
    expect(find.text('Advanced'), findsWidgets);
    expect(find.text('Awaiting evaluation'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('board-technical')));
    await tester.pumpAndSettle();
    expect(fake.boardsAsked.last, 'technical');
    expect(find.text('90.0'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('trader-daniel_crypto365')));
    await tester.pumpAndSettle();
    expect(find.text('Strengths'), findsOneWidget);
    expect(find.text('Clear invalidation levels'), findsOneWidget);
    expect(find.text('Mostly bullish calls'), findsOneWidget);
    expect(find.text('CoinMarketCap profile'), findsOneWidget);
    expect(find.textContaining('Confidence 66.0%'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Technical analysis'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Technical analysis'), findsOneWidget);
  });

  testWidgets('fits a phone', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    final model = SearchFeedViewModel(
        dependencies: AppDependencies.withService(FakeTraderaService()));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: model,
                builder: (context, _) => CustomScrollView(
                    slivers: traderLeaderboardSlivers(context, model, 16))))));
    await model.loadTraders();
    await tester.pumpAndSettle();
    expect(find.text('Daniel Markson'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trader-daniel_crypto365')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Clear invalidation levels'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Clear invalidation levels'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<(FakeTraderaService, SearchFeedViewModel)> openReport(
      WidgetTester tester,
      {required bool admin}) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    final fake = FakeTraderaService(admin: admin);
    final deps = AppDependencies.withService(fake);
    deps.sessionController.setSession(const Session(
        accountId: 'me',
        handle: 'test',
        token: 'x',
        privateKey: '',
        publicKey: ''));
    final model = SearchFeedViewModel(dependencies: deps);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: model,
                builder: (context, _) => CustomScrollView(
                    slivers: traderLeaderboardSlivers(context, model, 16))))));
    await model.loadTraders();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trader-daniel_crypto365')));
    await tester.pumpAndSettle();
    return (fake, model);
  }

  testWidgets(
      'everyone sees the trader\'s Tradera account, only admins manage it',
      (tester) async {
    await openReport(tester, admin: false);
    expect(find.textContaining('@daniel_crypto365 on Tradera'), findsOneWidget);
    expect(find.byKey(const ValueKey('trader-credentials')), findsNothing);
    expect(find.byKey(const ValueKey('trader-remove')), findsNothing);
  });

  testWidgets('an admin reads a trader\'s credentials', (tester) async {
    final (fake, _) = await openReport(tester, admin: true);
    await tester.tap(find.byKey(const ValueKey('trader-credentials')));
    await tester.pumpAndSettle();
    expect(fake.evaluatorCalls.single.$1, 'trader_credentials');
    expect(fake.evaluatorCalls.single.$2, {'handle': 'daniel_crypto365'});
    expect(find.text('Tradera account'), findsOneWidget);
    expect(find.text('Pw-7xQ2mK9vL4rT8nZ1a'), findsOneWidget);
  });

  testWidgets('an admin removes a trader, with or without their account',
      (tester) async {
    final (fake, _) = await openReport(tester, admin: true);
    await tester.tap(find.byKey(const ValueKey('trader-remove')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Daniel Markson?'), findsOneWidget);
    // Keep the account this time.
    await tester.tap(find.byKey(const ValueKey('remove-delete-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remove-confirm')));
    await tester.pumpAndSettle();
    expect(fake.evaluatorCalls.single.$1, 'trader_remove');
    expect(fake.evaluatorCalls.single.$2,
        {'handle': 'daniel_crypto365', 'keep_account': true});
    expect(find.text('Daniel Markson was removed'), findsOneWidget);
    expect(find.text('Strengths'), findsNothing); // the report closed

    await tester.tap(find.byKey(const ValueKey('trader-daniel_crypto365')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trader-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remove-confirm')));
    await tester.pumpAndSettle();
    expect(fake.evaluatorCalls.last.$1, 'trader_remove');
    expect(fake.evaluatorCalls.last.$2, {'handle': 'daniel_crypto365'});
  });
}
