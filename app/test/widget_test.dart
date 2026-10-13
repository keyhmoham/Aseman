import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tradera/src/app.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/data/models/space.dart';

import 'fake_tradera_service.dart';

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .clearAllTestValues();
  });

  Finder robotHead() => find.byWidgetPredicate((widget) =>
      widget is Image && widget.image.toString().contains('only_orb'));

  /// Seed a logged-in session so the shell mounts the feed instead of the
  /// auth screen. The app runs against the deterministic fake service, so the
  /// UI renders real-shaped backend data with no network.
  Future<void> seedSession() async {
    SharedPreferences.setMockInitialValues({
      'tradera.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
              '"token":"x","private_key":"","public_key":"",'
              '"home_space_id":"00000000000000010000000000000002"}',
    });
  }

  AppDependencies app() => AppDependencies.withService(FakeTraderaService());

  testWidgets('shows the auth screen before login', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    expect(find.text('Log in'), findsWidgets);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Tradera'), findsOneWidget);
  });

  testWidgets('lands on the search feed when a session exists', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    expect(robotHead(), findsOneWidget);
    expect(find.text('Global'), findsOneWidget);
    expect(find.text('Following'), findsOneWidget);
    expect(find.textContaining('Search'), findsWidgets);
  });

  testWidgets('search filters the feed', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'ETH');
    await tester.pumpAndSettle();
    expect(find.textContaining('results for “ETH”'), findsOneWidget);
  });

  testWidgets('switches workspace from the search feed app bar',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    expect(find.text('Switch workspace'), findsOneWidget);

    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();
    expect(find.text('My trading desk'), findsOneWidget);
    expect(find.text('Atlas Capital'), findsWidgets);

    await tester.tap(find.byTooltip('Search feed'));
    await tester.pumpAndSettle();
    expect(find.text('Global feed'), findsOneWidget);
  });

  testWidgets('new workspace hall room shows its own feed and the composer',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    // Open the desk first, then create a brand-new workspace from there.
    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();
    expect(find.text('My trading desk'), findsOneWidget);

    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New workspace'));
    await tester.pumpAndSettle();

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, 'New Alpha');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    // The hall room of the new workspace must show its own (empty) feed —
    // not the global feed — and the post composer.
    expect(find.text('No posts in this workspace yet.'), findsOneWidget);
    expect(find.text('Write a post for this workspace…'), findsOneWidget);
    expect(find.text('BTC consolidating above weekly VWAP.'), findsNothing);
  });

  testWidgets('new workspace has no bots until added', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New workspace'));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, 'New Alpha');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.text('My trading desk'), findsOneWidget);

    // Switch the library to the Agents tab.
    await tester.tap(find.byIcon(Icons.smart_toy_outlined).first);
    await tester.pumpAndSettle();

    // A fresh workspace must not come with agents by default.
    expect(find.text('Add agent'), findsOneWidget);
    expect(find.text('SignalBot'), findsNothing);
  });

  testWidgets('room chat mentions a workspace agent and triggers it',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();
    expect(find.text('My trading desk'), findsOneWidget);

    // Open the "general" room so the room chat shows.
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();
    expect(find.text('Live room'), findsOneWidget);

    // Open the mention picker and mention SignalBot.
    await tester.tap(find.byIcon(Icons.alternate_email_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Mention an agent'), findsOneWidget);
    await tester.tap(find.text('SignalBot'));
    await tester.pumpAndSettle();
    expect(find.text('@SignalBot'), findsOneWidget);

    // Sending the message keeps the structured mention attached.
    final composerField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Message room…');
    await tester.enterText(composerField, 'Please analyze BTC');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Please analyze BTC'), findsOneWidget);
  });

  testWidgets('traders tab shows the leaderboard', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    // The feed tab bar scrolls horizontally; bring the Traders tab into view.
    await tester.ensureVisible(find.text('Traders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Traders'));
    await tester.pumpAndSettle();
    expect(find.text('Traders leaderboard'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    expect(find.text('#3'), findsOneWidget);
    expect(find.text('Maya Chen'), findsOneWidget);
  });

  testWidgets('profile menu opens market and my bots', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('My bots'), findsOneWidget);
    expect(find.text('Market'), findsOneWidget);
    expect(find.text('Wallet'), findsOneWidget);

    await tester.tap(find.text('Market'));
    await tester.pumpAndSettle();
    expect(find.text('Publish'), findsOneWidget);
    expect(find.text('Install'), findsNothing); // empty market list
  });

  testWidgets('profile panels are responsive on mobile', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    // Mobile: the avatar opens the bottom sheet menu.
    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('My bots'), findsOneWidget);

    // Open the My bots panel as a bottom sheet; no overflow should occur.
    await tester.tap(find.text('My bots'));
    await tester.pumpAndSettle();
    expect(find.text('Create'), findsOneWidget);
    expect(find.text('Agents'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile profile menu opens the responsive admin console',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('Admin console'), findsOneWidget);

    await tester.ensureVisible(find.text('Admin console'));
    await tester.tap(find.text('Admin console'));
    await tester.pumpAndSettle();
    expect(find.text('Admin console'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('TRADERA ADMIN'), findsOneWidget);
    expect(find.text('Users'), findsWidgets);
    expect(find.text('Projects'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace header opens the profile popup on the feed',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    // The app bar has the profile avatar; tapping opens the popup menu.
    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);
  });

  testWidgets('room chat renders attachments and offers an attach button',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeTraderaService();
    // Seed a document attachment in the Atlas "general" room (upload + message).
    final doc = await service.uploadFile(
      FakeTraderaService.atlasId,
      roomId: 'a1',
      name: 'quarterly-report.pdf',
      mime: 'application/pdf',
      bytes: Uint8List.fromList(List.generate(900, (i) => i % 256)),
    );
    await service.sendRoomMessage(
      FakeTraderaService.atlasId,
      'a1',
      'See attached',
      attachments: [doc.id],
    );

    await tester.pumpWidget(
        TraderaApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    // The message body and the attached document preview render.
    expect(find.text('See attached'), findsOneWidget);
    expect(find.text('quarterly-report.pdf'), findsOneWidget);
    expect(find.textContaining('tap to download'), findsOneWidget);

    // The composer exposes an attach button (and the mention picker still
    // works alongside it).
    expect(find.byTooltip('Attach file'), findsOneWidget);
    expect(find.byTooltip('Mention an agent'), findsOneWidget);
  });

  testWidgets('workspace left panel classifies uploaded attachments',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeTraderaService();
    await service.uploadFile(
      FakeTraderaService.atlasId,
      roomId: 'a1',
      name: 'chart.png',
      mime: 'image/png',
      bytes: Uint8List.fromList(List.generate(400, (i) => i % 256)),
    );
    await service.uploadFile(
      FakeTraderaService.atlasId,
      roomId: 'a1',
      name: 'voice-note.mp3',
      mime: 'audio/mpeg',
      bytes: Uint8List.fromList(List.generate(300, (i) => i % 256)),
    );
    await service.uploadFile(
      FakeTraderaService.atlasId,
      roomId: 'a1',
      name: 'notes.txt',
      mime: 'text/plain',
      bytes: Uint8List.fromList(List.generate(200, (i) => i % 256)),
    );

    await tester.pumpWidget(
        TraderaApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();

    // Docs tab shows the text file.
    await tester.tap(find.byIcon(Icons.description_outlined));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);

    // Media tab shows the image.
    await tester.tap(find.byIcon(Icons.perm_media_outlined));
    await tester.pumpAndSettle();
    expect(find.text('chart.png'), findsOneWidget);

    // Audio tab shows the voice note.
    await tester.tap(find.byIcon(Icons.graphic_eq_rounded));
    await tester.pumpAndSettle();
    expect(find.text('voice-note.mp3'), findsOneWidget);
  });

  testWidgets('agent profile renders real backend data and wired action',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();

    // Open the Agents tab (Atlas has SignalBot installed).
    await tester.tap(find.byIcon(Icons.smart_toy_outlined).first);
    await tester.pumpAndSettle();

    // Open SignalBot's profile.
    await tester.tap(find.text('SignalBot').first);
    await tester.pumpAndSettle();

    // Real profile data is rendered: header title, the Agent runtime section
    // title, the installs stat label and the wired action button (SignalBot is
    // already installed in the Atlas workspace).
    expect(find.text('SignalBot'), findsWidgets);
    expect(find.text('Runtime'), findsOneWidget);
    expect(find.text('Installs'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
  });

  testWidgets('search scopes agents to the workspace vs the whole platform',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(TraderaApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();

    // Open the search/discover panel.
    await tester.tap(find.byIcon(Icons.travel_explore_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('In Atlas Capital'), findsOneWidget);
    expect(find.text('Explore Tradera'), findsOneWidget);

    // In-workspace Agents section → only the space's agent (SignalBot), not the
    // global AlphaBot. Each result card carries a WORKSPACE/GLOBAL tag.
    await tester.tap(find.widgetWithText(Tab, 'Agents'));
    await tester.pumpAndSettle();
    expect(find.text('WORKSPACE'), findsOneWidget);
    expect(find.text('SignalBot'), findsWidgets);
    expect(find.text('GLOBAL'), findsNothing);

    // Switch to the global Explore tab, Agents section → the platform agent
    // appears.
    await tester.tap(find.text('Explore Tradera'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Agents'));
    await tester.pumpAndSettle();
    expect(find.text('GLOBAL'), findsOneWidget);
    expect(find.text('AlphaBot'), findsWidgets);
  });

  testWidgets('tradera logs render as collapsible sections in the room',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeTraderaService();
    final now = DateTime.now();
    service.roomMessages['${FakeTraderaService.atlasId}/a1'] = [
      RoomMessage(
          id: 'm1',
          spaceId: FakeTraderaService.atlasId,
          roomId: 'a1',
          senderId: '00000000000000015c00dfede113ae2e',
          body: 'Ready.',
          createdAt: now),
      RoomMessage(
          id: 'm2',
          spaceId: FakeTraderaService.atlasId,
          roomId: 'a1',
          senderId: '00000000000000015c00dfede113ae2e',
          body: '## Execution Plan\n1. Inspect the workspace',
          kind: 'log',
          createdAt: now.add(const Duration(seconds: 1))),
    ];

    await tester.pumpWidget(
        TraderaApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    // The log renders as a collapsed section header, not a chat bubble.
    expect(find.text('Plan'), findsOneWidget);
    expect(find.textContaining('Execution Plan'), findsNothing);

    // Expanding the section reveals the log body.
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Execution Plan'), findsOneWidget);
  });

  testWidgets('room chat shows a working-agent indicator with the agent name',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeTraderaService();
    service.roomMessages['${FakeTraderaService.atlasId}/a1'] = [
      RoomMessage(
          id: 'm1',
          spaceId: FakeTraderaService.atlasId,
          roomId: 'a1',
          senderId: '00000000000000010000000000000099',
          body: 'hello',
          createdAt: DateTime.now()),
    ];
    // The backend reports that the dev agent is currently working.
    service.workingAgent = 'dev';

    await tester.pumpWidget(
        TraderaApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    // The indicator animates indefinitely, so pump fixed durations instead of
    // pumpAndSettle (which never settles while the animation repeats).
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('dev'), findsOneWidget);
    expect(find.text('agent is working'), findsOneWidget);

    // When the agent finishes (backend clears the signal), the indicator goes.
    service.workingAgent = '';
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('agent is working'), findsNothing);
  });

  testWidgets('proxy messages render an open-in-webview button',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeTraderaService();
    service.roomMessages['${FakeTraderaService.atlasId}/a1'] = [
      RoomMessage(
          id: 'm1',
          spaceId: FakeTraderaService.atlasId,
          roomId: 'a1',
          senderId: '00000000000000015c00dfede113ae2e',
          body:
              '🔗 **Landing Page** is now live on the gateway.\n\nOpen it: /v1/proxy/0000000000000001626f3df602aaad3d/',
          createdAt: DateTime.now()),
    ];

    await tester.pumpWidget(
        TraderaApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Landing Page'), findsOneWidget);
    expect(find.text('Open in webview'), findsOneWidget);
  });

  testWidgets('message designer sends a designed message to the room chat',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeTraderaService();
    await tester.pumpWidget(
        TraderaApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    // Open the designer from the composer.
    await tester.tap(find.byTooltip('Design a message'));
    await tester.pumpAndSettle();
    expect(find.text('Design a message'), findsOneWidget);

    // Author markdown and send it to the chat.
    await tester.enterText(
        find.descendant(
            of: find.byType(Dialog), matching: find.byType(TextField)),
        '## Hello\n\n- point one\n- point two');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send to chat'));
    await tester.pumpAndSettle();

    // The designed message is now in the chat, rendered as rich content.
    expect(find.textContaining('Hello'), findsWidgets);
    expect(find.text('point one'), findsWidgets);
    expect(find.text('point two'), findsWidgets);
  });
}
