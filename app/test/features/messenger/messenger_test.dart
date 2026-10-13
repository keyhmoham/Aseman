import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tradera/src/app.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/data/models/bot.dart';
import 'package:tradera/src/data/models/space.dart';

import '../../fake_tradera_service.dart';

/// Records what the messenger sends, and installs the direct chat's agent.
class _MessengerService extends FakeTraderaService {
  final sent = <({String space, String body, List<String> mentions})>[];

  @override
  Future<List<Bot>> fetchSpaceBots(String spaceId) async =>
      spaceId == FakeTraderaService.agentDirectId
          ? const <Bot>[
              Bot(
                  id: 'bot-alpha',
                  ownerId: 'me',
                  accountId: '00000000000000010000000000000043',
                  vmType: 'deepagents',
                  status: 'running',
                  name: 'AlphaBot',
                  kind: 'agent')
            ]
          : await super.fetchSpaceBots(spaceId);

  @override
  Future<RoomMessage> sendRoomMessage(
      String spaceId, String roomId, String body,
      {List<String> mentions = const [], List<String> attachments = const []}) {
    sent.add((space: spaceId, body: body, mentions: mentions));
    return super.sendRoomMessage(spaceId, roomId, body,
        mentions: mentions, attachments: attachments);
  }
}

void main() {
  Future<_MessengerService> openMessenger(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'tradera.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
              '"token":"x","private_key":"","public_key":"",'
              '"home_space_id":"00000000000000010000000000000002"}',
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _MessengerService();
    await tester.pumpWidget(
        TraderaApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Messages').last);
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('the menu opens wallet, invitations, usage and account directly',
      (tester) async {
    await openMessenger(tester);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('Account, billing, payouts & usage'), findsNothing);
    for (final item in ['Wallet', 'Invitations', 'Usage', 'Account']) {
      expect(find.text(item), findsWidgets, reason: item);
    }
  });

  testWidgets('lists direct chats and project rooms, filtered by tab',
      (tester) async {
    await openMessenger(tester);
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(find.text('AlphaBot'), findsOneWidget);
    expect(find.text('Atlas Capital'), findsOneWidget);

    await tester.tap(find.text('Direct · 2'));
    await tester.pumpAndSettle();
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(find.text('Atlas Capital'), findsNothing);

    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    expect(find.text('Maya Chen'), findsNothing);
    expect(find.text('Atlas Capital'), findsOneWidget);
  });

  testWidgets('a chat opens inside the messenger and back returns to the list',
      (tester) async {
    await openMessenger(tester);
    await tester.tap(find.text('Maya Chen'));
    await tester.pumpAndSettle();
    expect(find.text('Message Maya Chen…'), findsOneWidget);
    expect(find.byTooltip('Agent tasks'), findsOneWidget);
    expect(find.byTooltip('Attach file'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to chats'));
    await tester.pumpAndSettle();
    expect(find.text('Search chats'), findsOneWidget);
  });

  testWidgets('writing to an agent in its direct chat addresses the agent',
      (tester) async {
    final service = await openMessenger(tester);
    await tester.tap(find.text('AlphaBot'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Size a BTC long');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(service.sent, hasLength(1));
    expect(service.sent.single.space, FakeTraderaService.agentDirectId);
    expect(service.sent.single.mentions, ['bot-alpha']);
    // The read cursor follows the open chat.
    expect(service.seen, contains(FakeTraderaService.agentDirectId));
  });
}
