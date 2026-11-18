import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/network/session_store.dart';
import 'package:aseman/src/core/settings/app_settings.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/features/account/presentation/account_panel.dart';
import 'package:aseman/src/features/agents/presentation/agents_screen.dart';
import 'package:aseman/src/features/home/presentation/space_settings_panel.dart';
import 'package:aseman/src/features/home/presentation/widgets/routines_panel.dart';
import 'package:aseman/src/features/home/presentation/widgets/space_facility_tabs.dart';
import 'package:aseman/src/features/market/presentation/bots_store_screen.dart';
import 'package:aseman/src/features/market/presentation/market_screen.dart';
import 'package:aseman/src/features/messenger/presentation/chat_page.dart';
import 'package:aseman/src/features/messenger/presentation/messenger_panel.dart';
import 'package:aseman/src/features/search_feed/presentation/search_feed_screen.dart';
import 'package:aseman/src/features/settings/presentation/settings_screen.dart';
import 'package:aseman/src/shared/widgets/workspace_header.dart';

import '../fake_aseman_service.dart';
import '../features/admin/admin_fixtures.dart' show loadFonts;

Finder profileAvatar() => find.descendant(
  of: find.byType(WorkspaceHeader),
  matching: find.byTooltip(WorkspaceHeader.profileTooltip),
);

Future<void> openProfile(WidgetTester tester, {required bool phone}) async {
  if (phone) {
    await tester.tap(
      find.descendant(of: find.byType(HomeTabBar), matching: find.text('You')),
    );
  } else {
    await tester.tap(profileAvatar());
  }
  await tester.pumpAndSettle();
}

/// Renders every main screen at phone and desktop sizes and fails on any
/// layout error. Writes screenshots when UI_SHOTS names a directory.
final shots = Platform.environment['UI_SHOTS'];

const sizes = {'phone': Size(390, 844), 'desktop': Size(1440, 900)};

void main() {
  setUpAll(() async {
    // The chat composer creates an audio recorder; tests have no plugin.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
    if (shots != null) await loadFonts();
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAllTestValues();
  });

  AppDependencies deps() {
    final d = AppDependencies.withService(FakeAsemanService());
    d.sessionController.setSession(
      const Session(
        accountId: 'me',
        handle: 'test',
        token: 'x',
        privateKey: '',
        publicKey: '',
        homeSpaceId: FakeAsemanService.homeId,
      ),
    );
    return d;
  }

  Future<void> seedSession() async {
    SharedPreferences.setMockInitialValues({
      'aseman.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
          '"token":"x","private_key":"","public_key":"",'
          '"home_space_id":"00000000000000010000000000000002"}',
    });
  }

  Future<List<String>> capture(
    WidgetTester tester,
    Size size,
    String name,
    Future<void> Function() build,
  ) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final culprit = RegExp(
        r'The relevant error-causing widget was:\s*\n\s*(.*)\n\s*(.*)',
      ).firstMatch(details.toString());
      errors.add(
        '${details.exceptionAsString().split('\n').first}'
        '${culprit == null ? '' : ' @ ${culprit.group(1)} ${culprit.group(2)}'}',
      );
    };
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    try {
      await build();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (shots != null) {
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile(Uri.file('$shots/$name.png')),
        );
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      FlutterError.onError = previous;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
    return errors;
  }

  Widget host(Widget child) => AppSettingsScope(
    controller: AppSettingsController(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkWith(const Color(0xFF8B7BFF)),
      home: child is Scaffold ? child : Scaffold(body: child),
    ),
  );

  final screens = <String, Widget Function(AppDependencies)>{
    'settings': (d) => SettingsScreen(dependencies: d),
    'messenger': (d) => MessengerPanel(dependencies: d),
    'chat_direct': (d) => ChatPage(
          dependencies: d,
          chat: FakeAsemanService()
              .chats
              .firstWhere((c) => c.direct && !c.saved && !(c.peer?.isAgent ?? false)),
        ),
    'chat_agent': (d) => ChatPage(
          dependencies: d,
          chat: FakeAsemanService()
              .chats
              .firstWhere((c) => c.peer?.isAgent ?? false),
        ),
    'market': (d) => MarketScreen(dependencies: d),
    'my_bots': (d) => AgentsScreen(dependencies: d),
    'bots_store': (d) => BotsStoreScreen(dependencies: d),
    for (final area in AccountArea.values)
      'account_${area.name}': (d) => AccountPanel(dependencies: d, area: area),
    // The space's facility tabs, at the left panel's width.
    for (final tab in ['computer', 'memory', 'previews'])
      'space_$tab': (d) => Scaffold(
        body: Center(
          child: SizedBox(
            width: 210,
            height: 600,
            child: switch (tab) {
              'computer' => SpaceComputerTab(
                dependencies: d,
                spaceId: FakeAsemanService.atlasId,
              ),
              'memory' => SpaceMemoryTab(
                dependencies: d,
                spaceId: FakeAsemanService.atlasId,
              ),
              _ => SpacePreviewsTab(
                dependencies: d,
                spaceId: FakeAsemanService.atlasId,
              ),
            },
          ),
        ),
      ),
    'space_settings': (d) => Scaffold(
      body: SpaceSettingsPanel(
        dependencies: d,
        space: const Workspace(
          id: FakeAsemanService.atlasId,
          ownerId: 'me',
          name: 'Atlas Collective',
        ),
      ),
    ),
    'routines': (d) => Scaffold(
      body: RoutinesPanel(
        dependencies: d,
        spaceId: FakeAsemanService.atlasId,
        roomId: 'room-1',
        roomName: 'General',
      ),
    ),
  };

  // A fake service whose Atlas "general" room already holds a conversation.
  FakeAsemanService roomService() {
    final service = FakeAsemanService();
    final t = DateTime(2026, 3, 4, 9, 30);
    RoomMessage msg(
      String id,
      String sender,
      String body,
      int minute, {
      String kind = 'message',
    }) => RoomMessage(
      id: id,
      spaceId: FakeAsemanService.atlasId,
      roomId: 'a1',
      senderId: sender,
      body: body,
      kind: kind,
      createdAt: t.add(Duration(minutes: minute)),
    );
    service.roomMessages['${FakeAsemanService.atlasId}/a1'] = [
      msg(
        'm1',
        '00000000000000010000000000000042',
        'Morning team. The onboarding flow is ready for review.',
        0,
      ),
      msg(
        'm2',
        '00000000000000010000000000000001',
        'Nice. @AlphaBot can you size a long with 2% risk?',
        2,
      ),
      msg(
        'm3',
        'bot-alpha',
        'Plan: gather feedback, draft fixes, share with the room.',
        3,
        kind: 'log',
      ),
      msg(
        'm4',
        'bot-alpha',
        'Assigned AssistBot to summarize open threads before standup.',
        4,
      ),
      msg('m5', '00000000000000010000000000000001', 'Perfect, thanks!', 5),
    ];
    return service;
  }

  for (final size in sizes.entries) {
    for (final screen in screens.entries) {
      testWidgets('${size.key} · ${screen.key}', (tester) async {
        final errors = await capture(
          tester,
          size.value,
          '${size.key}_${screen.key}',
          () async {
            await tester.pumpWidget(host(screen.value(deps())));
          },
        );
        expect(errors, isEmpty);
      });
    }

    testWidgets('${size.key} · app flows', (tester) async {
      Future<void> app(
        String name, [
        Future<void> Function()? interact,
        FakeAsemanService? service,
      ]) async {
        await seedSession();
        final errors = await capture(
          tester,
          size.value,
          '${size.key}_$name',
          () async {
            await tester.pumpWidget(
              AsemanApp(
                dependencies: AppDependencies.withService(
                  service ?? FakeAsemanService(),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await interact?.call();
            await tester.pumpAndSettle();
          },
        );
        expect(errors, isEmpty, reason: name);
      }

      // Opens Atlas Collective from the home chats list.
      Future<void> openAtlas() async {
        await tester.tap(find.text('Atlas Collective').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('general').first);
        await tester.pumpAndSettle();
      }

      Future<void> openMessages() async {
        final nav = AsemanApp.navigatorKey.currentContext!;
        final deps = tester
            .widget<AsemanApp>(find.byType(AsemanApp))
            .dependencies;
        unawaited(showMessenger(nav, deps));
        await tester.pumpAndSettle();
      }

      final phone = size.key == 'phone';
      await app('feed');
      await app('profile_menu', () => openProfile(tester, phone: phone));
      await app('widgets_library', () async {
        await tester.tap(find.byTooltip('Widgets & windows'));
        await tester.pumpAndSettle();
      });
      await app('workspace', openAtlas);
      await app('room', () async {
        await openAtlas();
        await tester.pumpAndSettle();
        if (phone) {
          await tester.tap(find.byTooltip('Rooms and workspace').first);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('general').first);
        if (phone) {
          await tester.pumpAndSettle();
          await tester.tap(find.text('Chat').last);
        }
      }, roomService());
      await app('menu_wallet', () async {
        await openProfile(tester, phone: phone);
        await tester.tap(find.text('Wallet').last);
      });
      await app('menu_invitations', () async {
        await tester.tap(find.byTooltip('Notifications'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Invites').last);
      });
      await app('messenger', () async {
        await openAtlas();
        await tester.pumpAndSettle();
        if (phone) {
          // The profile menu has no Messages shortcut; phones open chats from Home.
          await tester.tap(find.widgetWithText(FilledButton, 'Home'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(HomeTabBar),
              matching: find.text('Chats'),
            ),
          );
        } else {
          await openMessages();
        }
      }, roomService());
      await app('messenger_spaces', () async {
        await openAtlas();
        await tester.pumpAndSettle();
        if (phone) {
          await tester.tap(find.widgetWithText(FilledButton, 'Home'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(HomeTabBar),
              matching: find.text('Chats'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Spaces').last);
        } else {
          await openMessages();
          await tester.tap(find.text('Rooms').last);
        }
      }, roomService());
      await app('messenger_chat', () async {
        await openAtlas();
        await tester.pumpAndSettle();
        if (phone) {
          await tester.tap(find.widgetWithText(FilledButton, 'Home'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(HomeTabBar),
              matching: find.text('Chats'),
            ),
          );
          await tester.pumpAndSettle();
        } else {
          await openMessages();
        }
        await tester.tap(
          find.descendant(
            of: find.byType(MessengerPanel),
            matching: find.text('Atlas Collective'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(MessengerPanel),
            matching: find.text('general'),
          ),
        );
      }, roomService());
      // On a phone the feed is the Explore tab (the app opens on Chats).
      Future<void> openFeed() async {
        if (!phone) return;
        await tester.tap(
          find.descendant(
            of: find.byType(HomeTabBar),
            matching: find.text('Explore'),
          ),
        );
        await tester.pumpAndSettle();
      }

      await app('feed_following', () async {
        await openFeed();
        await tester.tap(find.text('Following').first);
      });
      // Spaces and Chats: the chats list's filter (a phone's Chats tab).
      await app('feed_spaces', () async {
        await tester.tap(find.text('Spaces').first);
      });
      await app('feed_chats', () async {
        await tester.tap(find.text('Chats').first);
      });
      await app('feed_explore', () async {
        await openFeed();
        await tester.tap(find.text('Search Aseman…'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'a');
      });
      SharedPreferences.setMockInitialValues({});
      final errors = await capture(
        tester,
        size.value,
        '${size.key}_auth',
        () async {
          await tester.pumpWidget(
            AsemanApp(
              dependencies: AppDependencies.withService(FakeAsemanService()),
            ),
          );
          await tester.pumpAndSettle();
        },
      );
      expect(errors, isEmpty, reason: 'auth');
    });
  }
}
