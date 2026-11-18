import 'dart:io';

import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/network/session_store.dart';
import 'package:aseman/src/core/settings/app_settings.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/core/theme/default_theme_packs.dart';
import 'package:aseman/src/core/theme/theme_pack.dart';
import 'package:aseman/src/core/theme/theme_pack_controller.dart';
import 'package:aseman/src/features/account/presentation/account_panel.dart';
import 'package:aseman/src/features/agents/presentation/agents_screen.dart';
import 'package:aseman/src/features/market/presentation/bots_store_screen.dart';
import 'package:aseman/src/features/market/presentation/market_screen.dart';
import 'package:aseman/src/features/messenger/presentation/chat_page.dart';
import 'package:aseman/src/features/messenger/presentation/messenger_panel.dart';
import 'package:aseman/src/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_aseman_service.dart';
import '../features/admin/admin_fixtures.dart' show loadFonts;

/// Renders the app's main screens under every built-in theme pack, in light
/// and dark, at a phone and a desktop size. Fails on any layout error, and on
/// any bottom sheet at desktop width. Set UI_SHOTS to write screenshots;
/// UI_PACKS (comma separated ids such as `sky,paper`) narrows the packs.
final _shots = Platform.environment['UI_SHOTS'];
final _only = Platform.environment['UI_PACKS']?.split(',');

const _sizes = {'phone': Size(390, 844), 'desktop': Size(1440, 900)};

void main() {
  setUpAll(() async {
    // The chat composer creates an audio recorder; tests have no plugin.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
    if (_shots != null) await loadFonts();
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAllTestValues();
  });

  AppDependencies deps() {
    final d = AppDependencies.withService(FakeAsemanService());
    d.sessionController.setSession(
      const Session(
        accountId: '00000000000000010000000000000001',
        handle: 'test',
        token: 'x',
        privateKey: '',
        publicKey: '',
        homeSpaceId: FakeAsemanService.homeId,
      ),
    );
    return d;
  }

  Widget host(ThemePack pack, bool dark, Widget child) {
    final settings = AppSettingsController()
      ..themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    final packs = ThemePackController()..pack = pack;
    settings.syncPaletteToPack(pack);
    return AppSettingsScope(
      controller: settings,
      child: ThemePackScope(
        controller: packs,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightWith(
            settings.accent,
            pack: pack,
            paletteId: settings.paletteId,
          ),
          darkTheme: AppTheme.darkWith(
            settings.accent,
            pack: pack,
            paletteId: settings.paletteId,
          ),
          themeMode: settings.themeMode,
          home: child is Scaffold ? child : Scaffold(body: child),
        ),
      ),
    );
  }

  final screens = <String, Widget Function(AppDependencies)>{
    'settings': (d) => SettingsScreen(dependencies: d),
    'messenger': (d) => MessengerPanel(dependencies: d),
    'chat_direct': (d) => ChatPage(
      dependencies: d,
      chat: FakeAsemanService().chats.firstWhere(
        (c) => c.direct && !c.saved && !(c.peer?.isAgent ?? false),
      ),
    ),
    'chat_agent': (d) => ChatPage(
      dependencies: d,
      chat: FakeAsemanService().chats.firstWhere(
        (c) => c.peer?.isAgent ?? false,
      ),
    ),
    'market': (d) => MarketScreen(dependencies: d),
    'my_bots': (d) => AgentsScreen(dependencies: d),
    'bots_store': (d) => BotsStoreScreen(dependencies: d),
    'wallet': (d) => AccountPanel(dependencies: d, area: AccountArea.wallet),
    'account': (d) => AccountPanel(dependencies: d, area: AccountArea.account),
  };

  Future<List<String>> run(
    WidgetTester tester,
    Size size,
    String name,
    Future<void> Function() build, {
    bool desktop = false,
  }) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final culprit = RegExp(
        r'The relevant error-causing widget was:\s*\n\s*(.*)\n\s*(.*)',
      ).firstMatch(details.toString());
      if (Platform.environment['UI_TRACE'] != null) {
        // ignore: avoid_print
        print(details.toString().split('\n').take(60).join('\n'));
      }
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
      if (desktop && find.byType(BottomSheet).evaluate().isNotEmpty) {
        errors.add('bottom sheet shown on desktop');
      }
      if (_shots != null) {
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile(Uri.file('$_shots/$name.png')),
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

  for (final pack in DefaultThemePacks.all) {
    final short = pack.id.replaceFirst('builtin.', '');
    final only = _only;
    if (only != null && !only.contains(short)) continue;
    for (final dark in [false, true]) {
      for (final size in _sizes.entries) {
        final mode = dark ? 'dark' : 'light';
        final tag = '$short · $mode · ${size.key}';
        final desktop = size.key == 'desktop';

        testWidgets('$tag · screens', (tester) async {
          final failures = <String>[];
          for (final screen in screens.entries) {
            SharedPreferences.setMockInitialValues({});
            final errors = await run(
              tester,
              size.value,
              '${short}_${mode}_${size.key}_${screen.key}',
              () async {
                await tester.pumpWidget(
                  host(pack, dark, screen.value(deps())),
                );
              },
              desktop: desktop,
            );
            failures.addAll([for (final e in errors) '${screen.key}: $e']);
          }
          expect(failures, isEmpty);
        });

        testWidgets('$tag · app shell', (tester) async {
          final failures = <String>[];
          Future<void> shell(
            String name, [
            Future<void> Function()? interact,
          ]) async {
            SharedPreferences.setMockInitialValues({
              'aseman.session':
                  '{"account_id":"00000000000000010000000000000001",'
                  '"handle":"test","token":"x","private_key":"",'
                  '"public_key":"",'
                  '"home_space_id":"00000000000000010000000000000002"}',
              ThemePackController.idKey: pack.id,
              AppSettingsController.storageKey: '{"mode":"$mode"}',
            });
            final errors = await run(
              tester,
              size.value,
              '${short}_${mode}_${size.key}_$name',
              () async {
                await tester.pumpWidget(
                  AsemanApp(
                    dependencies: AppDependencies.withService(
                      FakeAsemanService(),
                    ),
                  ),
                );
                await tester.pumpAndSettle();
                await interact?.call();
                await tester.pumpAndSettle();
              },
              desktop: desktop,
            );
            failures.addAll([for (final e in errors) '$name: $e']);
          }

          await shell('shell_home');
          await shell('shell_atlas', () async {
            final atlas = find.text('Atlas Collective');
            if (atlas.evaluate().isNotEmpty) await tester.tap(atlas.first);
          });
          if (!desktop) {
            await shell('shell_you', () async {
              await tester.tap(find.text('You').last);
            });
          }
          expect(failures, isEmpty);
        });
      }
    }
  }
}
