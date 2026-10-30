import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/space.dart';

import 'fake_aseman_service.dart';

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .clearAllTestValues();
  });

  /// Seed a logged-in session so the shell mounts the feed instead of the
  /// auth screen. The app runs against the deterministic fake service, so the
  /// UI renders real-shaped backend data with no network.
  Future<void> seedSession() async {
    SharedPreferences.setMockInitialValues({
      'aseman.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
              '"token":"x","private_key":"","public_key":"",'
              '"home_space_id":"00000000000000010000000000000002"}',
    });
  }

  AppDependencies app() => AppDependencies.withService(FakeAsemanService());

  testWidgets('shows the auth screen before login', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    expect(find.text('Log in'), findsWidgets);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Aseman'), findsOneWidget);
  });

  testWidgets('lands on the search feed when a session exists', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    expect(find.text('Global'), findsNothing);
    expect(find.text('Traders'), findsNothing);
    expect(find.text('Following'), findsOneWidget);
    expect(find.text('Search Aseman…'), findsOneWidget);

    // The spaces picker on the left, the messenger on the right.
    expect(find.text('Spaces'), findsWidgets);
    expect(find.text('Atlas Capital'), findsWidgets);
    expect(find.text('Chats'), findsWidgets);
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(find.text('AlphaBot'), findsOneWidget);

    // Space posts are mixed into the feed, tagged with their space.
    expect(find.text('Private update inside the Home workspace.'),
        findsOneWidget);
  });

  testWidgets('phone home bottom nav switches chats, spaces and explore',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    Finder navLabel(String label) => find.descendant(
        of: find.byType(NavigationBar), matching: find.text(label));

    // Phones land on the Chats tab.
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(navLabel('Chats'), findsOneWidget);
    expect(navLabel('Spaces'), findsOneWidget);
    expect(navLabel('Explore'), findsOneWidget);

    await tester.tap(navLabel('Spaces'));
    await tester.pumpAndSettle();
    expect(find.text('Atlas Capital'), findsWidgets);
    expect(find.text('Open a workspace or start a new one'), findsOneWidget);

    await tester.tap(navLabel('Explore'));
    await tester.pumpAndSettle();
    expect(find.text('Search Aseman…'), findsOneWidget);
    expect(find.text('Private update inside the Home workspace.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the feed search bar opens Explore without the space tabs',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final service = FakeAsemanService();
    await tester.pumpWidget(AsemanApp(
        dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Search Aseman…'));
    await tester.pumpAndSettle();
    expect(find.text('Explore'), findsOneWidget);
    // Outside a space there is no space/explore scope to pick.
    expect(find.text('Explore Aseman'), findsNothing);

    // Explore sits over the feed, whose side panels list the same names.
    Finder inExplore(String text) => find.text(text).last;
    await tester.enterText(find.byType(TextField).last, 'a');
    await tester.pumpAndSettle();
    expect(inExplore('maya'), findsOneWidget);

    await tester.tap(find.text('Chats').last);
    await tester.pumpAndSettle();
    expect(inExplore('Maya Chen'), findsOneWidget);

    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    expect(inExplore('Atlas Capital'), findsOneWidget);

    await tester.tap(find.text('Agents').last);
    await tester.pumpAndSettle();
    expect(inExplore('AlphaBot'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'home');
    await tester.tap(find.text('Posts').last);
    await tester.pumpAndSettle();
    expect(inExplore('Private update inside the Home workspace.'),
        findsOneWidget);
    expect(service.postSearches.last, ('home', true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a space found in Explore opens it, a chat opens the chat',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    // Explore sits over the feed, whose side panels list the same names.
    Finder inExplore(String text) => find.text(text).last;
    // The feed's search bar opens Explore.
    await tester.tap(find.text('Search Aseman…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chats').last);
    await tester.pumpAndSettle();
    await tester.tap(inExplore('Maya Chen'));
    await tester.pumpAndSettle();
    expect(find.text('Message Maya Chen…'), findsOneWidget);
    // The chat opened from Explore is a modal over it.
    await tester.tap(find.byTooltip('Close').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    await tester.tap(inExplore('Atlas Capital'));
    await tester.pumpAndSettle();
    expect(find.text('My trading desk'), findsOneWidget);
  });

  testWidgets('switches workspace from the feed and the desk switcher',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    // A space in the feed's Spaces panel opens its desk.
    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();
    expect(find.text('My trading desk'), findsOneWidget);

    // On the desk, the edge handle opens the switcher.
    await tester.tap(find.byTooltip('Switch workspace'));
    await tester.pumpAndSettle();
    expect(find.text('Switch workspace'), findsOneWidget);
    expect(find.text('New workspace'), findsOneWidget);

    // The switcher's feed tile returns to the feed.
    await tester.tap(find.text('Your feed').last);
    await tester.pumpAndSettle();
    expect(find.text('People and agents you follow, and your spaces'),
        findsOneWidget);
  });

  testWidgets('new workspace hall room shows its own feed and the composer',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    // Open the desk first, then create a brand-new workspace from there.
    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();
    expect(find.text('My trading desk'), findsOneWidget);

    await tester.tap(find.byTooltip('Switch workspace'));
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
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch workspace'));
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
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
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

  testWidgets('profile menu opens market and my bots', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('My bots'), findsOneWidget);
    expect(find.text('Market'), findsOneWidget);
    expect(find.text('Wallet'), findsOneWidget);
    // Messages is a workspace-desk entry, not the feed's.
    expect(find.text('Messages'), findsNothing);

    await tester.tap(find.text('Market'));
    await tester.pumpAndSettle();
    expect(find.text('Publish'), findsOneWidget);
    expect(find.text('Install'), findsNothing); // empty market list
  });

  testWidgets('profile panels are responsive on mobile', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
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
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('Admin console'), findsOneWidget);

    await tester.ensureVisible(find.text('Admin console'));
    await tester.tap(find.text('Admin console'));
    await tester.pumpAndSettle();
    // On phones the app bar names the current admin page.
    expect(find.text('What needs attention'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(Drawer), matching: find.text('Admin console')),
        findsOneWidget);
    expect(find.text('Users'), findsWidgets);
    expect(find.text('Projects'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile menu hides the admin console from non-admins',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(
        dependencies:
            AppDependencies.withService(FakeAsemanService(admin: false))));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('My bots'), findsOneWidget);
    expect(find.text('Admin console'), findsNothing);
  });

  testWidgets('workspace header opens the profile popup on the feed',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    // The app bar has the profile avatar; tapping opens the popup menu.
    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Messages'), findsNothing);
  });

  testWidgets('workspace profile menu includes Messages', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CircleAvatar).first);
    await tester.pumpAndSettle();
    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('My bots'), findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);
  });

  testWidgets('room chat renders attachments and offers an attach button',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeAsemanService();
    // Seed a document attachment in the Atlas "general" room (upload + message).
    final doc = await service.uploadFile(
      FakeAsemanService.atlasId,
      roomId: 'a1',
      name: 'quarterly-report.pdf',
      mime: 'application/pdf',
      bytes: Uint8List.fromList(List.generate(900, (i) => i % 256)),
    );
    await service.sendRoomMessage(
      FakeAsemanService.atlasId,
      'a1',
      'See attached',
      attachments: [doc.id],
    );

    await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    // The message body and the attached document preview render.
    expect(find.text('See attached'), findsOneWidget);
    expect(find.text('quarterly-report.pdf'), findsOneWidget);
    expect(find.textContaining('tap to open'), findsOneWidget);

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

    final service = FakeAsemanService();
    await service.uploadFile(
      FakeAsemanService.atlasId,
      roomId: 'a1',
      name: 'chart.png',
      mime: 'image/png',
      bytes: Uint8List.fromList(List.generate(400, (i) => i % 256)),
    );
    await service.uploadFile(
      FakeAsemanService.atlasId,
      roomId: 'a1',
      name: 'voice-note.mp3',
      mime: 'audio/mpeg',
      bytes: Uint8List.fromList(List.generate(300, (i) => i % 256)),
    );
    await service.uploadFile(
      FakeAsemanService.atlasId,
      roomId: 'a1',
      name: 'notes.txt',
      mime: 'text/plain',
      bytes: Uint8List.fromList(List.generate(200, (i) => i % 256)),
    );

    await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
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
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
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
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();

    // Open the search/discover panel (the left panel's search button).
    await tester.tap(find.byIcon(Icons.search_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('In Atlas Capital'), findsOneWidget);
    expect(find.text('Explore Aseman'), findsOneWidget);

    // In-workspace Agents section → only the space's agent (SignalBot), not the
    // global AlphaBot.
    await tester.tap(find.widgetWithText(Tab, 'Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Results from Atlas Capital workspace'), findsOneWidget);
    expect(find.text('SignalBot'), findsWidgets);

    // Switch to the global Explore tab, Agents section → the platform agent
    // appears.
    await tester.tap(find.text('Explore Aseman'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Discover across the platform'), findsOneWidget);
    expect(find.text('AlphaBot'), findsWidgets);
  });

  testWidgets('aseman logs render as collapsible sections in the room',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeAsemanService();
    final now = DateTime.now();
    service.roomMessages['${FakeAsemanService.atlasId}/a1'] = [
      RoomMessage(
          id: 'm1',
          spaceId: FakeAsemanService.atlasId,
          roomId: 'a1',
          senderId: '00000000000000015c00dfede113ae2e',
          body: 'Ready.',
          createdAt: now),
      RoomMessage(
          id: 'm2',
          spaceId: FakeAsemanService.atlasId,
          roomId: 'a1',
          senderId: '00000000000000015c00dfede113ae2e',
          body: '## Execution Plan\n1. Inspect the workspace',
          kind: 'log',
          createdAt: now.add(const Duration(seconds: 1))),
    ];

    await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
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

    final service = FakeAsemanService();
    service.roomMessages['${FakeAsemanService.atlasId}/a1'] = [
      RoomMessage(
          id: 'm1',
          spaceId: FakeAsemanService.atlasId,
          roomId: 'a1',
          senderId: '00000000000000010000000000000099',
          body: 'hello',
          createdAt: DateTime.now()),
    ];
    // The backend reports that the dev agent is currently working.
    service.workingAgent = 'dev';

    await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    // The indicator animates indefinitely, so pump fixed durations instead of
    // pumpAndSettle (which never settles while the animation repeats).
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('dev'), findsOneWidget);
    expect(find.text('working'), findsOneWidget);

    // When the agent finishes (backend clears the signal), the indicator goes.
    service.workingAgent = '';
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('working'), findsNothing);
  });

  testWidgets('proxy messages render an open-on-the-desk button',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeAsemanService();
    service.roomMessages['${FakeAsemanService.atlasId}/a1'] = [
      RoomMessage(
          id: 'm1',
          spaceId: FakeAsemanService.atlasId,
          roomId: 'a1',
          senderId: '00000000000000015c00dfede113ae2e',
          body:
              '🔗 **Landing Page** is now live on the gateway.\n\nOpen it: /v1/proxy/0000000000000001626f3df602aaad3d/',
          createdAt: DateTime.now()),
    ];

    await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Landing Page'), findsOneWidget);
    expect(find.text('Open on the desk'), findsOneWidget);
  });

  testWidgets('message designer sends a designed message to the room chat',
      (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeAsemanService();
    await tester.pumpWidget(
        AsemanApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ASEMAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
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
