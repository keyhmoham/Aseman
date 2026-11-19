import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/features/home/presentation/workspace_screen.dart';
import 'package:aseman/src/features/messenger/presentation/chat_page.dart';
import 'package:aseman/src/features/messenger/presentation/messenger_panel.dart';
import 'package:aseman/src/features/search_feed/presentation/search_feed_screen.dart';
import 'package:aseman/src/shared/widgets/profile_menu.dart';
import 'package:aseman/src/shared/widgets/workspace_header.dart';

import '../../fake_aseman_service.dart';

Finder profileAvatar() => find.descendant(
  of: find.byType(WorkspaceHeader),
  matching: find.byTooltip(WorkspaceHeader.profileTooltip),
);

Future<void> openAtlas(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Chats'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Atlas Collective').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('general').first);
  await tester.pumpAndSettle();
}

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
            vmType: 'harness',
            status: 'running',
            name: 'AlphaBot',
            kind: 'agent',
          ),
        ]
      : await super.fetchSpaceBots(spaceId);

  @override
  Future<RoomMessage> sendRoomMessage(
    String spaceId,
    String roomId,
    String body, {
    List<String> mentions = const [],
    List<String> attachments = const [],
    String replyTo = '',
  }) {
    sent.add((
      space: spaceId,
      body: body,
      mentions: mentions,
      replyTo: replyTo,
    ));
    return super.sendRoomMessage(
      spaceId,
      roomId,
      body,
      mentions: mentions,
      attachments: attachments,
      replyTo: replyTo,
    );
  }
}

void main() {
  /// Matches inside the messenger only: the feed under it lists the same
  /// spaces and direct chats in its side panels.
  Finder inMessenger(Finder finder) =>
      find.descendant(of: find.byType(MessengerPanel), matching: finder);

  /// Matches inside the open chat only — the workspace under a floating
  /// direct-chat modal can host another [ChatPage] with the same chrome.
  Finder inChat(Finder finder) => find.descendant(
    of: find.byType(ChatPage).last,
    matching: finder,
  );

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
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pumpAndSettle();
    final nav = AsemanApp.navigatorKey.currentContext!;
    final deps = tester.widget<AsemanApp>(find.byType(AsemanApp)).dependencies;
    unawaited(showMessenger(nav, deps));
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets(
    'the feed profile menu opens store and wallet without invitations',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'aseman.session':
            '{"account_id":"00000000000000010000000000000001","handle":"test",'
            '"token":"x","private_key":"","public_key":"",'
            '"home_space_id":"00000000000000010000000000000002"}',
      });
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(_MessengerService())),
      );
      await tester.pumpAndSettle();
      await tester.tap(profileAvatar());
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ProfileMenuBody),
          matching: find.text('Store'),
        ),
        findsOneWidget,
      );
      expect(find.text('Wallet'), findsOneWidget);
      expect(find.text('Invitations'), findsNothing);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Invites'), findsOneWidget);
      await tester.tap(find.text('Invites'));
      await tester.pumpAndSettle();
      expect(find.text('No invitations'), findsOneWidget);
    },
  );

  testWidgets('lists direct chats and one row per space, filtered by tab', (
    tester,
  ) async {
    await openMessenger(tester);
    expect(inMessenger(find.text('Maya Chen')), findsOneWidget);
    expect(inMessenger(find.text('AlphaBot')), findsOneWidget);
    expect(inMessenger(find.text('Atlas Collective')), findsOneWidget);
    // A space's rooms stay folded until that space is spread open.
    expect(inMessenger(find.text('general')), findsNothing);

    await tester.tap(find.text('Direct · 2'));
    await tester.pumpAndSettle();
    expect(inMessenger(find.text('Maya Chen')), findsOneWidget);
    expect(inMessenger(find.text('Atlas Collective')), findsNothing);

    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    expect(inMessenger(find.text('Maya Chen')), findsNothing);
    expect(inMessenger(find.text('Atlas Collective')), findsOneWidget);
  });

  testWidgets(
    'a direct chat opens as a floating modal and close returns to the list',
    (tester) async {
      await openMessenger(tester);
      await tester.tap(inMessenger(find.text('Maya Chen')));
      await tester.pumpAndSettle();
      expect(find.text('Message Maya Chen…'), findsOneWidget);
      expect(inChat(find.byTooltip('Work')), findsOneWidget);
      expect(inChat(find.byTooltip('Attach file')), findsOneWidget);
      // Direct chats float above the messenger: close the chat, not the list.
      final closeChat = find.descendant(
        of: find.byType(ChatPage),
        matching: find.byTooltip('Close'),
      );
      expect(closeChat, findsOneWidget);

      await tester.tap(closeChat);
      await tester.pumpAndSettle();
      expect(find.text('Search chats'), findsOneWidget);
      // The home assistant stays open behind the messenger.
      expect(find.byType(ChatPage), findsOneWidget);
    },
  );

  testWidgets('a project room chat still opens inside the messenger panel', (
    tester,
  ) async {
    await openMessenger(tester);
    await tester.tap(inMessenger(find.text('Atlas Collective')));
    await tester.pumpAndSettle();
    await tester.tap(inMessenger(find.text('general')));
    await tester.pumpAndSettle();
    expect(find.text('Message general…'), findsOneWidget);
    expect(find.byTooltip('Back to chats'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to chats'));
    await tester.pumpAndSettle();
    expect(find.text('Search chats'), findsOneWidget);
  });

  /// The home chats list (desktop rail or phone Chats tab), not the floating
  /// messenger opened from a workspace.
  Future<void> openHomeChats(
    WidgetTester tester,
    Size size, [
    FakeAsemanService? service,
  ]) async {
    SharedPreferences.setMockInitialValues({
      'aseman.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
          '"token":"x","private_key":"","public_key":"",'
          '"home_space_id":"00000000000000010000000000000002"}',
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AsemanApp(
        dependencies: AppDependencies.withService(
          service ?? FakeAsemanService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (size.width >= 840) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('Chats'),
        ),
      );
      await tester.pumpAndSettle();
    }
  }

  /// Enough direct chats that the list is taller than either the phone tab
  /// or the desktop rail.
  FakeAsemanService longChatList() {
    final service = FakeAsemanService();
    service.chats = [
      ...service.chats,
      for (var i = 0; i < 24; i++)
        ChatSummary(
          spaceId:
              '0000000000000001000000000000005${i.toString().padLeft(2, '0')}',
          roomId: 'extra-$i',
          direct: true,
          spaceName: 'Direct',
          roomName: 'general',
          role: 'owner',
          peer: ChatPeer(id: 'peer-$i', handle: 'person$i', name: 'Person $i'),
          lastBody: 'Hello $i',
          updatedAt: DateTime(2026, 1, 1, 0, i),
        ),
    ];
    return service;
  }

  bool shareScrollable(Finder a, Finder b) {
    final scrollsOf = (Finder target) =>
        find.ancestor(of: target, matching: find.byType(Scrollable)).evaluate();
    final shared = scrollsOf(a).toSet().intersection(scrollsOf(b).toSet());
    return shared.isNotEmpty;
  }

  Future<void> openAtlasRoomFromChats(WidgetTester tester) async {
    await tester.tap(inMessenger(find.text('Atlas Collective')));
    await tester.pumpAndSettle();
    await tester.tap(inMessenger(find.text('general')));
    await tester.pumpAndSettle();
  }

  testWidgets('new chat covers the list while people and agents load', (
    tester,
  ) async {
    await openHomeChats(tester, const Size(1440, 900));
    expect(inMessenger(find.text('Maya Chen')), findsOneWidget);

    await tester.tap(inMessenger(find.byTooltip('New')));
    await tester.pumpAndSettle();
    expect(find.text('New space'), findsOneWidget);
    expect(find.text('New chat'), findsOneWidget);
    await tester.tap(find.text('New chat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final back = find.byTooltip('Back to chats');
    expect(back, findsOneWidget);
    final scaffold = tester.widget<Scaffold>(
      find.ancestor(of: back, matching: find.byType(Scaffold)).first,
    );
    expect(scaffold.backgroundColor, isNot(Colors.transparent));
    expect(scaffold.backgroundColor!.a, 1);

    await tester.pumpAndSettle();
    expect(find.text('Search people and agents by @handle'), findsOneWidget);
    expect(
      tester
          .widget<Scaffold>(
            find.ancestor(of: back, matching: find.byType(Scaffold)).first,
          )
          .backgroundColor!
          .a,
      1,
    );
  });

  testWidgets('new space from the chats FAB opens the create workspace dialog', (
    tester,
  ) async {
    await openHomeChats(tester, const Size(1440, 900));

    await tester.tap(inMessenger(find.byTooltip('New')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New space'));
    await tester.pumpAndSettle();

    expect(find.text('New workspace'), findsOneWidget);
    expect(find.text('Workspace name'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create'), findsOneWidget);
  });

  testWidgets(
    'a room in the desktop chats rail opens that room in its workspace',
    (tester) async {
      await openHomeChats(tester, const Size(1440, 900));
      await openAtlasRoomFromChats(tester);

      expect(find.byType(ChatPage), findsNothing);
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(find.text('Search chats'), findsOneWidget);
      expect(find.text('general desk'), findsOneWidget);
      expect(find.text('My desk'), findsNothing);
      expect(find.text('Message room…'), findsOneWidget);
      expect(find.text('Private note inside Atlas Collective.'), findsNothing);
      expect(find.byTooltip('Workspace home'), findsOneWidget);
    },
  );

  testWidgets(
    'a room in the phone chats tab opens that room in its workspace',
    (tester) async {
      await openHomeChats(tester, const Size(400, 800));
      expect(find.byType(HomeTabBar), findsOneWidget);
      await openAtlasRoomFromChats(tester);

      expect(find.byType(ChatPage), findsNothing);
      expect(find.byType(HomeTabBar), findsNothing);
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(find.text('general desk'), findsOneWidget);
      expect(find.text('My desk'), findsNothing);

      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      expect(find.text('Message room…'), findsOneWidget);
      expect(find.text('Private note inside Atlas Collective.'), findsNothing);
    },
  );

  testWidgets('workspace Home returns to the phone chats tab', (tester) async {
    await openHomeChats(tester, const Size(400, 800));
    await openAtlasRoomFromChats(tester);
    expect(find.byType(WorkspaceScreen), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Home'));
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceScreen), findsNothing);
    expect(find.byType(HomeTabBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(HomeTabBar),
        matching: find.byIcon(Icons.forum_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(HomeTabBar),
        matching: find.byIcon(Icons.widgets_rounded),
      ),
      findsNothing,
    );
    expect(find.text('Maya Chen', skipOffstage: true), findsOneWidget);
    expect(find.text('Your desk', skipOffstage: true), findsNothing);
  });

  testWidgets('the All, Direct and Spaces bar is centered horizontally', (
    tester,
  ) async {
    Future<void> expectCentered(Size size) async {
      await openHomeChats(tester, size);
      final panel = tester.getRect(find.byType(MessengerPanel));
      final bar = tester.getRect(inMessenger(find.byType(TabBar)));
      expect(bar.center.dx, closeTo(panel.center.dx, 1));
    }

    await expectCentered(const Size(400, 800));
    await expectCentered(const Size(1440, 900));
  });

  testWidgets('the phone chats tab scrolls the header with the list', (
    tester,
  ) async {
    await openHomeChats(tester, const Size(400, 800), longChatList());
    final header = inMessenger(find.text('Chats'));
    final search = inMessenger(find.text('Search chats'));
    final row = inMessenger(find.text('Maya Chen'));
    expect(shareScrollable(search, row), isTrue);
    final scroll = tester.state<ScrollableState>(
      find
          .ancestor(
            of: row,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first,
    );

    final headerY = tester.getTopLeft(header).dy;
    final searchY = tester.getTopLeft(search).dy;
    scroll.position.jumpTo(72);
    await tester.pump();

    expect(tester.getTopLeft(header).dy, closeTo(headerY - 72, 1));
    expect(tester.getTopLeft(search).dy, closeTo(searchY - 72, 1));
  });

  testWidgets(
    'the desktop chats rail keeps its header fixed while the list scrolls',
    (tester) async {
      await openHomeChats(tester, const Size(1440, 900), longChatList());
      final header = inMessenger(find.text('Chats'));
      final search = inMessenger(find.text('Search chats'));
      final row = inMessenger(find.text('Maya Chen'));
      expect(shareScrollable(search, row), isFalse);
      final scroll = tester.state<ScrollableState>(
        find
            .ancestor(
              of: row,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      expect(scroll.position.pixels, 0);

      final headerY = tester.getTopLeft(header).dy;
      final searchY = tester.getTopLeft(search).dy;
      await tester.drag(row, const Offset(0, -180));
      await tester.pump();

      expect(scroll.position.pixels, greaterThan(40));
      expect(tester.getTopLeft(header).dy, closeTo(headerY, 0.5));
      expect(tester.getTopLeft(search).dy, closeTo(searchY, 0.5));
    },
  );

  testWidgets('writing to an agent in its direct chat addresses the agent', (
    tester,
  ) async {
    final service = await openMessenger(tester);
    await tester.tap(inMessenger(find.text('AlphaBot')));
    await tester.pumpAndSettle();
    await tester.enterText(
      inChat(find.byType(TextField)).last,
      'Draft the kickoff agenda',
    );
    await tester.pump();
    await tester.tap(inChat(find.byTooltip('Send')));
    await tester.pumpAndSettle();
    expect(service.sent, hasLength(1));
    expect(service.sent.single.space, FakeAsemanService.agentDirectId);
    // A bare note names nobody: the founding peer of the direct space runs.
    expect(service.sent.single.mentions, isEmpty);
    // The read cursor follows the open chat.
    expect(service.seen, contains(FakeAsemanService.agentDirectId));
  });

  const me = '00000000000000010000000000000001';
  const maya = '00000000000000010000000000000042';
  const mayaRoom = '${FakeAsemanService.directId}/d1';

  RoomMessage msg(
    String id,
    String sender,
    String body,
    int minute, {
    String replyTo = '',
    DateTime? editedAt,
  }) => RoomMessage(
    id: id,
    spaceId: FakeAsemanService.directId,
    roomId: 'd1',
    senderId: sender,
    body: body,
    createdAt: DateTime(2026, 3, 4, 9, minute),
    replyTo: replyTo,
    editedAt: editedAt,
  );

  Future<void> openMaya(WidgetTester tester) async {
    await tester.tap(inMessenger(find.text('Maya Chen')));
    await tester.pumpAndSettle();
  }

  testWidgets('a direct chat shows replies, edits, typing and what was seen', (
    tester,
  ) async {
    final service = await openMessenger(tester);
    service.roomMessages[mayaRoom] = [
      msg('m1', maya, 'Desk review tomorrow?', 1),
      msg('m2', me, 'Yes, at ten', 2, replyTo: 'm1'),
      msg(
        'm3',
        me,
        'Bring the charts',
        3,
        editedAt: DateTime(2026, 3, 4, 9, 4),
      ),
    ];
    service.chatState[FakeAsemanService.directId] = RoomChatPage(
      typing: const ['Maya Chen'],
      peerSeenAt: DateTime(2026, 3, 4, 9, 2),
    );
    await openMaya(tester);
    // The reply quotes what it answers; the edit says so.
    expect(find.text('Desk review tomorrow?'), findsNWidgets(2));
    expect(find.textContaining('edited ·'), findsOneWidget);
    expect(find.text('Maya Chen is typing…'), findsOneWidget);
    // Maya read up to the reply, not the later message.
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
  });

  testWidgets('replying, editing and deleting go through the message menu', (
    tester,
  ) async {
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
    await tester.enterText(inChat(find.byType(TextField)).last, 'Sure');
    await tester.pump();
    await tester.tap(inChat(find.byTooltip('Send')));
    await tester.pumpAndSettle();
    expect(service.sent.single.replyTo, 'm1');
    expect(find.text('Reply to Maya Chen'), findsNothing);

    await tester.longPress(find.text('Yes, at tem'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit message'), findsOneWidget);
    await tester.enterText(inChat(find.byType(TextField)).last, 'Yes, at ten');
    await tester.pump();
    await tester.tap(inChat(find.byTooltip('Send')));
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

  testWidgets('someone else\'s message is reported with a reason', (
    tester,
  ) async {
    final service = await openMessenger(tester);
    service.roomMessages[mayaRoom] = [msg('m1', maya, 'Send me your seed', 1)];
    await openMaya(tester);
    await tester.longPress(find.text('Send me your seed'));
    await tester.pumpAndSettle();
    expect(
      find.text('Delete for everyone'),
      findsNothing,
      reason: 'nobody moderates the other side of a direct chat',
    );
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scam or fraud'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Report'));
    await tester.pumpAndSettle();
    expect(service.chatCalls, contains('report:m1:scam'));
  });

  testWidgets('blocking a chat replaces the composer until it is unblocked', (
    tester,
  ) async {
    final service = await openMessenger(tester);
    await openMaya(tester);
    await tester.tap(inChat(find.byTooltip('Chat options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();
    expect(service.chatCalls, contains('block:00000000000000010000000000000042'));
    expect(find.textContaining('You blocked this chat'), findsOneWidget);
    expect(inChat(find.byTooltip('Send')), findsNothing);

    await tester.tap(inChat(find.byTooltip('Chat options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(inChat(find.byTooltip('Record a voice message')), findsOneWidget);
  });

  testWidgets('a long-pressed direct chat is pinned to the top of the list', (
    tester,
  ) async {
    final service = await openMessenger(tester);
    await tester.longPress(inMessenger(find.text('Maya Chen')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin to top'));
    await tester.pumpAndSettle();
    expect(service.chatCalls.single, startsWith('pin:'));
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
  });

  testWidgets('long-pressing a space spreads its rooms in the chat list', (
    tester,
  ) async {
    final service = await openMessenger(tester);
    service.chats = [
      ...service.chats,
      ChatSummary(
        spaceId: FakeAsemanService.atlasId,
        roomId: 'a2',
        spaceName: 'Atlas Collective',
        roomName: 'research',
        role: 'owner',
        lastBody: 'Charts are in',
        updatedAt: DateTime(2026, 3, 2),
      ),
    ];
    // The list reloads on its own; the next poll picks up the new room.
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expect(inMessenger(find.text('Atlas Collective')), findsOneWidget);
    expect(inMessenger(find.text('general')), findsNothing);
    expect(inMessenger(find.text('research')), findsNothing);

    await tester.longPress(inMessenger(find.text('Atlas Collective')));
    await tester.pumpAndSettle();
    expect(find.text('Pin to top'), findsNothing);
    expect(inMessenger(find.text('general')), findsOneWidget);
    expect(inMessenger(find.text('research')), findsOneWidget);
    // Still one space row, with its rooms nested under it.
    expect(inMessenger(find.text('Atlas Collective')), findsOneWidget);

    await tester.tap(inMessenger(find.text('research')));
    await tester.pumpAndSettle();
    expect(find.text('Message research…'), findsOneWidget);
  });

  testWidgets('right-clicking a space spreads its rooms in the chat list', (
    tester,
  ) async {
    await openMessenger(tester);
    expect(inMessenger(find.text('general')), findsNothing);
    await tester.tap(
      inMessenger(find.text('Atlas Collective')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(inMessenger(find.text('general')), findsOneWidget);
    expect(find.text('Pin to top'), findsNothing);
  });

  testWidgets('the Decillion assistant opens the chat with oneself', (tester) async {
    // Personal Aseman is a normal inbox row on the chats rail (not a header
    // shortcut). The home Aseman tab may already host the same chat.
    await openHomeChats(tester, const Size(1440, 900));
    expect(inMessenger(find.text('Decillion assistant')), findsOneWidget);
    await tester.tap(inMessenger(find.text('Decillion assistant')));
    await tester.pumpAndSettle();
    expect(find.text('Message Decillion assistant…'), findsWidgets);
    expect(find.text('Your personal assistant'), findsWidgets);
    await tester.tap(find.byTooltip('Chat options').last);
    await tester.pumpAndSettle();
    expect(find.text('Block'), findsNothing);
    expect(find.text('Report chat'), findsNothing);
  });
}
