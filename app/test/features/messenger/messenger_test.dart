import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/features/messenger/presentation/chat_page.dart';
import 'package:aseman/src/features/messenger/presentation/messenger_panel.dart';

import '../../fake_aseman_service.dart';

/// Records what the messenger sends, and installs the direct chat's agent.
class _MessengerService extends FakeAsemanService {
  final sent =
      <({String space, String body, List<String> mentions, String replyTo})>[];

  @override
  Future<List<Bot>> fetchSpaceBots(String spaceId) async =>
      spaceId == FakeAsemanService.agentDirectId
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
      {List<String> mentions = const [],
      List<String> attachments = const [],
      String replyTo = ''}) {
    sent.add(
        (space: spaceId, body: body, mentions: mentions, replyTo: replyTo));
    return super.sendRoomMessage(spaceId, roomId, body,
        mentions: mentions, attachments: attachments, replyTo: replyTo);
  }
}

void main() {
  /// Matches inside the messenger only: the feed under it lists the same
  /// spaces and direct chats in its side panels.
  Finder inMessenger(Finder finder) =>
      find.descendant(of: find.byType(MessengerPanel), matching: finder);

  Future<_MessengerService> openMessenger(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'aseman.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
              '"token":"x","private_key":"","public_key":"",'
              '"home_space_id":"00000000000000010000000000000002"}',
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _MessengerService();
    await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    // Messages lives in the workspace profile menu, not the feed's.
    await tester.tap(find.text('Atlas Capital').last);
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
    expect(inMessenger(find.text('Maya Chen')), findsOneWidget);
    expect(inMessenger(find.text('AlphaBot')), findsOneWidget);
    expect(inMessenger(find.text('Atlas Capital')), findsOneWidget);

    await tester.tap(find.text('Direct · 2'));
    await tester.pumpAndSettle();
    expect(inMessenger(find.text('Maya Chen')), findsOneWidget);
    expect(inMessenger(find.text('Atlas Capital')), findsNothing);

    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    expect(inMessenger(find.text('Maya Chen')), findsNothing);
    expect(inMessenger(find.text('Atlas Capital')), findsOneWidget);
  });

  testWidgets(
      'a direct chat opens as a floating modal and close returns to the list',
      (tester) async {
    await openMessenger(tester);
    await tester.tap(inMessenger(find.text('Maya Chen')));
    await tester.pumpAndSettle();
    expect(find.text('Message Maya Chen…'), findsOneWidget);
    expect(find.byTooltip('Work'), findsOneWidget);
    expect(find.byTooltip('Attach file'), findsOneWidget);
    // Direct chats float above the messenger: close the chat, not the list.
    final closeChat = find.descendant(
        of: find.byType(ChatPage), matching: find.byTooltip('Close'));
    expect(closeChat, findsOneWidget);

    await tester.tap(closeChat);
    await tester.pumpAndSettle();
    expect(find.text('Search chats'), findsOneWidget);
    expect(find.byType(ChatPage), findsNothing);
  });

  testWidgets(
      'a project room chat still opens inside the messenger panel',
      (tester) async {
    await openMessenger(tester);
    await tester.tap(inMessenger(find.text('general').last));
    await tester.pumpAndSettle();
    expect(find.text('Message general…'), findsOneWidget);
    expect(find.byTooltip('Back to chats'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to chats'));
    await tester.pumpAndSettle();
    expect(find.text('Search chats'), findsOneWidget);
  });

  testWidgets('writing to an agent in its direct chat addresses the agent',
      (tester) async {
    final service = await openMessenger(tester);
    await tester.tap(inMessenger(find.text('AlphaBot')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Size a BTC long');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(service.sent, hasLength(1));
    expect(service.sent.single.space, FakeAsemanService.agentDirectId);
    expect(service.sent.single.mentions, ['bot-alpha']);
    // The read cursor follows the open chat.
    expect(service.seen, contains(FakeAsemanService.agentDirectId));
  });

  const me = '00000000000000010000000000000001';
  const maya = '00000000000000010000000000000042';
  const mayaRoom = '${FakeAsemanService.directId}/d1';

  RoomMessage msg(String id, String sender, String body, int minute,
          {String replyTo = '', DateTime? editedAt}) =>
      RoomMessage(
          id: id,
          spaceId: FakeAsemanService.directId,
          roomId: 'd1',
          senderId: sender,
          body: body,
          createdAt: DateTime(2026, 3, 4, 9, minute),
          replyTo: replyTo,
          editedAt: editedAt);

  Future<void> openMaya(WidgetTester tester) async {
    await tester.tap(inMessenger(find.text('Maya Chen')));
    await tester.pumpAndSettle();
  }

  testWidgets('a direct chat shows replies, edits, typing and what was seen',
      (tester) async {
    final service = await openMessenger(tester);
    service.roomMessages[mayaRoom] = [
      msg('m1', maya, 'Desk review tomorrow?', 1),
      msg('m2', me, 'Yes, at ten', 2, replyTo: 'm1'),
      msg('m3', me, 'Bring the charts', 3,
          editedAt: DateTime(2026, 3, 4, 9, 4)),
    ];
    service.chatState[FakeAsemanService.directId] = RoomChatPage(
        typing: const ['Maya Chen'], peerSeenAt: DateTime(2026, 3, 4, 9, 2));
    await openMaya(tester);
    // The reply quotes what it answers; the edit says so.
    expect(find.text('Desk review tomorrow?'), findsNWidgets(2));
    expect(find.textContaining('edited ·'), findsOneWidget);
    expect(find.text('Maya Chen is typing…'), findsOneWidget);
    // Maya read up to the reply, not the later message.
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
  });

  testWidgets('replying, editing and deleting go through the message menu',
      (tester) async {
    final service = await openMessenger(tester);
    service.roomMessages[mayaRoom] = [
      msg('m1', maya, 'Desk review tomorrow?', 1),
      msg('m2', me, 'Yes, at tem', 2),
    ];
    await openMaya(tester);

    await tester.longPress(find.text('Desk review tomorrow?'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing, reason: 'not my message');
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.text('Reply to Maya Chen'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Sure');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(service.sent.single.replyTo, 'm1');
    expect(find.text('Reply to Maya Chen'), findsNothing);

    await tester.longPress(find.text('Yes, at tem'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit message'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Yes, at ten');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(service.chatCalls, contains('edit:m2'));
    expect(find.text('Yes, at ten'), findsOneWidget);

    await tester.longPress(find.text('Yes, at ten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete for everyone'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(service.chatCalls, contains('delete:m2'));
    expect(find.text('Yes, at ten'), findsNothing);
  });

  testWidgets('someone else\'s message is reported with a reason',
      (tester) async {
    final service = await openMessenger(tester);
    service.roomMessages[mayaRoom] = [msg('m1', maya, 'Send me your seed', 1)];
    await openMaya(tester);
    await tester.longPress(find.text('Send me your seed'));
    await tester.pumpAndSettle();
    expect(find.text('Delete for everyone'), findsNothing,
        reason: 'nobody moderates the other side of a direct chat');
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scam or fraud'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Report'));
    await tester.pumpAndSettle();
    expect(service.chatCalls, contains('report:m1:scam'));
  });

  testWidgets('blocking a chat replaces the composer until it is unblocked',
      (tester) async {
    final service = await openMessenger(tester);
    await openMaya(tester);
    await tester.tap(find.byTooltip('Chat options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();
    expect(service.chatCalls, contains('block:${FakeAsemanService.directId}'));
    expect(find.textContaining('You blocked this chat'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);

    await tester.tap(find.byTooltip('Chat options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Send'), findsOneWidget);
  });

  testWidgets('a long-pressed chat is pinned to the top of the list',
      (tester) async {
    final service = await openMessenger(tester);
    await tester.longPress(inMessenger(find.text('Atlas Capital')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin to top'));
    await tester.pumpAndSettle();
    expect(service.chatCalls.single, startsWith('pin:'));
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
  });

  testWidgets('Saved Messages opens the chat with oneself', (tester) async {
    await openMessenger(tester);
    await tester.tap(find.byTooltip('Saved Messages'));
    await tester.pumpAndSettle();
    expect(find.text('Write a note…'), findsOneWidget);
    expect(find.text('Notes, links and files for yourself'), findsOneWidget);
    await tester.tap(find.byTooltip('Chat options'));
    await tester.pumpAndSettle();
    expect(find.text('Block'), findsNothing);
    expect(find.text('Report chat'), findsNothing);
  });
}
