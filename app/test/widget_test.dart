import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app.dart';
import 'package:aseman/src/core/layout/app_layout.dart';
import 'package:aseman/src/features/search_feed/presentation/search_feed_screen.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/features/home/presentation/workspace_screen.dart'
    show exploreKey;
import 'package:aseman/src/shared/widgets/glass_surface.dart';
import 'package:aseman/src/shared/widgets/profile_menu.dart';
import 'package:aseman/src/shared/widgets/workspace_header.dart';

import 'fake_aseman_service.dart';

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAllTestValues();
  });

  /// Opens Atlas Collective from the home chats list (expand the space, then
  /// open a room — that jumps into the workspace).
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

  /// Profile avatar in the floating app bar (desktop only; phones use You).
  Finder profileAvatar() => find.descendant(
    of: find.byType(WorkspaceHeader),
    matching: find.byTooltip(WorkspaceHeader.profileTooltip),
  );

  /// Opens the phone You tab (replaces the app-bar avatar on compact widths).
  Future<void> openYouTab(WidgetTester tester) async {
    await tester.tap(
      find.descendant(of: find.byType(HomeTabBar), matching: find.text('You')),
    );
    await tester.pumpAndSettle();
  }

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
    expect(find.text('People'), findsNothing);
    expect(find.text('Following'), findsOneWidget);
    expect(find.text('Search people, agents, posts…'), findsOneWidget);

    // Large desktop: the feed is the supporting pane, Aseman the flexible
    // pane on its right. Chats are a destination, not a third column.
    expect(find.text('Desk'), findsWidgets);
    expect(find.text('Chat'), findsWidgets);
    final feedPane = find.ancestor(
      of: find.text('Following'),
      matching: find.byType(AppPane),
    );
    expect(tester.getSize(feedPane.first).width, greaterThan(280));
    expect(tester.getSize(feedPane.first).width, lessThan(420));
    final asemanPane = find.ancestor(
      of: find.text('Desk'),
      matching: find.byType(AppPane),
    );
    expect(
      tester.getTopLeft(asemanPane.first).dx,
      greaterThan(tester.getTopLeft(feedPane.first).dx),
    );
    expect(find.text('Maya Chen'), findsNothing);
    expect(find.text('Open a workspace or start a new one'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Chats'),
      ),
      findsOneWidget,
    );

    // Space posts are mixed into the feed, tagged with their space.
    expect(
      find.text('Private update inside the Home workspace.'),
      findsOneWidget,
    );
  });

  testWidgets('phone home bottom nav switches chats, explore and you', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    Finder navLabel(String label) => find.descendant(
      of: find.byType(HomeTabBar),
      matching: find.text(label),
    );

    // Phones land on the Chats tab. The bar is a short centered pill —
    // Chats, Explore and You (Aseman lives in the chats list).
    expect(find.text('Maya Chen'), findsOneWidget);
    final capsule = tester.getRect(
      find.descendant(
        of: find.byType(HomeTabBar),
        matching: find.byType(GlassSurface),
      ),
    );
    expect(capsule.width, lessThan(280));
    expect(capsule.center.dx, closeTo(195, 12));
    expect(navLabel('Chats'), findsOneWidget);
    expect(navLabel('Explore'), findsOneWidget);
    expect(navLabel('You'), findsOneWidget);
    expect(navLabel('Aseman'), findsNothing);

    await tester.tap(navLabel('Explore'));
    await tester.pumpAndSettle();
    expect(find.text('Search people, agents, posts…'), findsOneWidget);
    expect(
      find.text('Private update inside the Home workspace.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(navLabel('You'));
    await tester.pumpAndSettle();
    expect(find.text('Store'), findsOneWidget);
    expect(find.text('Wallet'), findsOneWidget);
    expect(find.text('Invitations'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Invites'), findsOneWidget);
    await tester.tap(find.text('Invites'));
    await tester.pumpAndSettle();
    expect(find.text('No invitations'), findsOneWidget);
    // Dismiss the notifications sheet via its barrier.
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    // Avatar is gone on phones; widgets library owns the top-right corner.
    expect(profileAvatar(), findsNothing);
    expect(find.byTooltip('Widgets & windows'), findsOneWidget);
    await tester.tap(find.byTooltip('Widgets & windows'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pinned widgets'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the feed search bar opens Explore without the space tabs', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final service = FakeAsemanService();
    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Search people, agents, posts…'));
    await tester.pumpAndSettle();
    expect(find.text('Explore'), findsOneWidget);
    // Outside a space there is no space/explore scope to pick.
    expect(find.text('Explore Aseman'), findsNothing);

    // Explore sits over the feed, whose side panels list the same names.
    Finder inExplore(String text) =>
        find.descendant(of: find.byKey(exploreKey), matching: find.text(text));
    await tester.enterText(find.byType(TextField).last, 'a');
    await tester.pumpAndSettle();
    expect(inExplore('maya'), findsOneWidget);

    await tester.tap(inExplore('Chats'));
    await tester.pumpAndSettle();
    expect(inExplore('Maya Chen'), findsOneWidget);

    await tester.tap(inExplore('Spaces'));
    await tester.pumpAndSettle();
    expect(inExplore('Atlas Collective'), findsOneWidget);

    await tester.tap(inExplore('Agents'));
    await tester.pumpAndSettle();
    expect(inExplore('AlphaBot'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'home');
    await tester.tap(inExplore('Posts'));
    await tester.pumpAndSettle();
    expect(
      inExplore('Private update inside the Home workspace.'),
      findsOneWidget,
    );
    expect(service.postSearches.last, ('home', true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a space found in Explore opens it, a chat opens the chat', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    // Explore sits over the feed, whose side panels list the same names.
    Finder inExplore(String text) =>
        find.descendant(of: find.byKey(exploreKey), matching: find.text(text));
    // The feed's search bar opens Explore.
    await tester.tap(find.text('Search people, agents, posts…'));
    await tester.pumpAndSettle();
    await tester.tap(inExplore('Chats'));
    await tester.pumpAndSettle();
    await tester.tap(inExplore('Maya Chen'));
    await tester.pumpAndSettle();
    expect(find.text('Message Maya Chen…'), findsOneWidget);
    // The chat opened from Explore is a modal over it.
    await tester.tap(find.byTooltip('Close').last);
    await tester.pumpAndSettle();

    await tester.tap(inExplore('Spaces'));
    await tester.pumpAndSettle();
    await tester.tap(inExplore('Atlas Collective'));
    await tester.pumpAndSettle();
    expect(find.text('My desk'), findsOneWidget);
  });

  testWidgets('leaving a workspace returns to the chats list', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await openAtlas(tester);
    expect(find.text('general desk'), findsOneWidget);
    expect(find.byTooltip('Switch workspace'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Spaces'),
      ),
      findsNothing,
    );

    final gadgets = tester.getRect(find.byTooltip('Gadgets'));
    expect(gadgets.center.dy, closeTo(450, 8));
    expect(gadgets.right, closeTo(1440, 2));

    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    expect(find.text('general desk'), findsNothing);
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Chats'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('new workspace hall room shows its own feed and the composer', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Chats'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New space'));
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
    expect(find.text('Shipped the onboarding polish with AssistBot.'), findsNothing);
  });

  testWidgets('new workspace has no bots until added', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Chats'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New space'));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, 'New Alpha');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.text('My desk'), findsOneWidget);

    // Switch the library to the Agents tab.
    await tester.tap(find.byIcon(Icons.smart_toy_outlined).first);
    await tester.pumpAndSettle();

    // A fresh workspace must not come with agents by default.
    expect(find.text('Add agent'), findsOneWidget);
    expect(find.text('AssistBot'), findsNothing);
  });

  testWidgets('room chat mentions a workspace agent and triggers it', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    // Opening Atlas lands on its general room (its desk, then its chat).
    await openAtlas(tester);
    expect(find.text('general desk'), findsOneWidget);
    expect(find.text('Live room'), findsOneWidget);

    // Open the mention picker and mention AssistBot.
    await tester.tap(find.byIcon(Icons.alternate_email_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Mention an agent'), findsOneWidget);
    await tester.tap(find.text('AssistBot'));
    await tester.pumpAndSettle();
    expect(find.text('@AssistBot'), findsOneWidget);

    // Sending the message keeps the structured mention attached.
    final composerField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Message room…',
    );
    await tester.enterText(composerField, 'Please summarize the room notes');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Please summarize the room notes'), findsOneWidget);
  });

  testWidgets('profile menu opens the store and wallet', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
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
    expect(
      find.descendant(
        of: find.byType(ProfileMenuBody),
        matching: find.text('Settings'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(ProfileMenuBody),
        matching: find.byTooltip('Settings'),
      ),
      findsOneWidget,
    );
    expect(find.text('Hire talent'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ProfileMenuBody),
        matching: find.text('Account'),
      ),
      findsNothing,
    );
    // Messages is a workspace-desk entry, not the feed's.
    expect(find.text('Messages'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(ProfileMenuBody),
        matching: find.text('Store'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Discover'), findsOneWidget);
    await tester.tap(find.text('Discover'));
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

    // Mobile: the You tab shows the profile body inline.
    await openYouTab(tester);
    expect(find.text('Store'), findsOneWidget);

    // Open the Store panel as a bottom sheet; no overflow should occur.
    await tester.tap(find.text('Store'));
    await tester.pumpAndSettle();
    expect(find.text('Create'), findsOneWidget);
    expect(find.text('Agents'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile profile menu opens the responsive admin console', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await openYouTab(tester);
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
        of: find.byType(Drawer),
        matching: find.text('Admin console'),
      ),
      findsOneWidget,
    );
    expect(find.text('Users'), findsWidgets);
    expect(find.text('Projects'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile menu hides the admin console from non-admins', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      AsemanApp(
        dependencies: AppDependencies.withService(
          FakeAsemanService(admin: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await openYouTab(tester);
    expect(find.text('Store'), findsOneWidget);
    expect(find.text('Admin console'), findsNothing);
  });

  testWidgets('workspace header opens the profile popup on the feed', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    // The app bar has the profile avatar; tapping opens the popup menu.
    await tester.tap(profileAvatar());
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ProfileMenuBody),
        matching: find.text('Store'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ProfileMenuBody),
        matching: find.text('Settings'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(ProfileMenuBody),
        matching: find.byTooltip('Settings'),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.settings_outlined), findsWidgets);
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Messages'), findsNothing);
  });

  testWidgets('workspace profile menu omits Messages', (tester) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await openAtlas(tester);
    await tester.tap(profileAvatar());
    await tester.pumpAndSettle();
    expect(find.text('Messages'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ProfileMenuBody),
        matching: find.text('Store'),
      ),
      findsOneWidget,
    );
    expect(find.text('Log out'), findsOneWidget);
  });

  testWidgets('room chat renders attachments and offers an attach button', (
    tester,
  ) async {
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
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pumpAndSettle();

    await openAtlas(tester);

    // The message body and the attached document preview render.
    expect(find.text('See attached'), findsOneWidget);
    expect(find.text('quarterly-report.pdf'), findsOneWidget);
    expect(find.textContaining('tap to open'), findsOneWidget);

    // The composer exposes an attach button (and the mention picker still
    // works alongside it).
    expect(find.byTooltip('Attach file'), findsOneWidget);
    expect(find.byTooltip('Mention an agent'), findsOneWidget);
  });

  testWidgets('workspace left panel classifies uploaded attachments', (
    tester,
  ) async {
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
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pumpAndSettle();

    await openAtlas(tester);

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

  testWidgets('agent profile renders real backend data and wired action', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await openAtlas(tester);

    // Open the Agents tab (Atlas has AssistBot installed).
    await tester.tap(find.byIcon(Icons.smart_toy_outlined).first);
    await tester.pumpAndSettle();

    // Open AssistBot's profile.
    await tester.tap(find.text('AssistBot').first);
    await tester.pumpAndSettle();

    // Real profile data is rendered: header title, the Agent runtime section
    // title, the installs stat label and the wired action button (AssistBot is
    // already installed in the Atlas workspace).
    expect(find.text('AssistBot'), findsWidgets);
    expect(find.text('Runtime'), findsOneWidget);
    expect(find.text('Installs'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
  });

  testWidgets('search scopes agents to the workspace vs the whole platform', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AsemanApp(dependencies: app()));
    await tester.pumpAndSettle();

    await openAtlas(tester);

    // Open the search/discover panel (the left panel's search button).
    await tester.tap(find.byTooltip('Find rooms'));
    await tester.pumpAndSettle();
    expect(find.text('In Atlas Collective'), findsOneWidget);
    expect(find.text('Explore Aseman'), findsOneWidget);

    // In-workspace Agents section → only the space's agent (AssistBot), not the
    // global AlphaBot.
    await tester.tap(find.widgetWithText(Tab, 'Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Results from Atlas Collective workspace'), findsOneWidget);
    expect(find.text('AssistBot'), findsWidgets);

    // Switch to the global Explore tab, Agents section → the platform agent
    // appears.
    await tester.tap(find.text('Explore Aseman'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Discover across the platform'), findsOneWidget);
    expect(find.text('AlphaBot'), findsWidgets);
  });

  testWidgets('aseman logs render as collapsible sections in the room', (
    tester,
  ) async {
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
        createdAt: now,
      ),
      RoomMessage(
        id: 'm2',
        spaceId: FakeAsemanService.atlasId,
        roomId: 'a1',
        senderId: '00000000000000015c00dfede113ae2e',
        body: '## Execution Plan\n1. Inspect the workspace',
        kind: 'log',
        createdAt: now.add(const Duration(seconds: 1)),
      ),
    ];

    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pumpAndSettle();
    await openAtlas(tester);

    // The log renders as a collapsed section header, not a chat bubble.
    expect(find.text('Plan'), findsOneWidget);
    expect(find.textContaining('Execution Plan'), findsNothing);

    // Expanding the section reveals the log body.
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Execution Plan'), findsOneWidget);
  });

  testWidgets('room chat shows a working-agent indicator with the agent name', (
    tester,
  ) async {
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
        createdAt: DateTime.now(),
      ),
    ];
    // The backend reports that the dev agent is currently working.
    service.workingAgent = 'dev';

    // A working agent's indicator animates indefinitely (in the chats list
    // too), so pump fixed durations instead of pumpAndSettle, which never
    // settles while the animation repeats.
    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    // Home has no repeating indicator, so the shell can settle before the
    // room (and its working indicator) is opened.
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Chats'),
      ),
    );
    // The list itself does not repeat. The room indicator does, so settle
    // only up to the point the room opens.
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Collective').first);
    await tester.pumpAndSettle();
    // The space expands with an AnimatedSize; give that animation a frame to
    // start and finish before tapping the room inside it.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('general').first);
    // The feed's panels animate out before the workspace opens, then the
    // workspace panes animate in. The working indicator repeats, so this
    // cannot use pumpAndSettle.
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.text('dev').evaluate().isNotEmpty) break;
    }

    expect(find.text('dev'), findsOneWidget);
    expect(find.text('working'), findsOneWidget);

    // When the agent finishes (backend clears the signal), the indicator goes.
    service.workingAgent = '';
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('working'), findsNothing);
  });

  testWidgets('proxy messages render an open-on-the-desk button', (
    tester,
  ) async {
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
        createdAt: DateTime.now(),
      ),
    ];

    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pumpAndSettle();
    await openAtlas(tester);

    expect(find.textContaining('Landing Page'), findsOneWidget);
    expect(find.text('Open on the desk'), findsOneWidget);
  });

  testWidgets('message designer sends a designed message to the room chat', (
    tester,
  ) async {
    await seedSession();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;

    final service = FakeAsemanService();
    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pumpAndSettle();
    await openAtlas(tester);

    // Open the designer from the composer's "+" menu.
    await tester.tap(find.byTooltip('Attach file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design a message'));
    await tester.pumpAndSettle();
    expect(find.text('Design a message'), findsWidgets);

    // Author markdown and send it to the chat.
    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      '## Hello\n\n- point one\n- point two',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send to chat'));
    await tester.pumpAndSettle();

    // The designed message is now in the chat, rendered as rich content.
    expect(find.textContaining('Hello'), findsWidgets);
    expect(find.text('point one'), findsWidgets);
    expect(find.text('point two'), findsWidgets);
  });
}
