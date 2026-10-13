import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tradera/src/app.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/core/network/session_store.dart';
import 'package:tradera/src/core/settings/app_settings.dart';
import 'package:tradera/src/core/theme/app_theme.dart';
import 'package:tradera/src/data/models/space.dart';
import 'package:tradera/src/features/account/presentation/account_hub_screen.dart';
import 'package:tradera/src/features/agents/presentation/agents_screen.dart';
import 'package:tradera/src/features/chats/presentation/chats_screen.dart';
import 'package:tradera/src/features/home/presentation/project_control_screen.dart';
import 'package:tradera/src/features/home/presentation/space_settings_panel.dart';
import 'package:tradera/src/features/home/presentation/widgets/routines_panel.dart';
import 'package:tradera/src/features/market/presentation/market_screen.dart';
import 'package:tradera/src/features/settings/presentation/settings_screen.dart';
import 'package:tradera/src/features/wallet/presentation/wallet_screen.dart';

import '../fake_tradera_service.dart';
import '../features/admin/admin_fixtures.dart' show loadFonts;

/// Renders every main screen at phone and desktop sizes and fails on any
/// layout error. Writes screenshots when UI_SHOTS names a directory.
final shots = Platform.environment['UI_SHOTS'];

const sizes = {'phone': Size(390, 844), 'desktop': Size(1440, 900)};

void main() {
  setUpAll(() async {
    if (shots != null) await loadFonts();
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .clearAllTestValues();
  });

  AppDependencies deps() {
    final d = AppDependencies.withService(FakeTraderaService());
    d.sessionController.setSession(const Session(
      accountId: 'me',
      handle: 'test',
      token: 'x',
      privateKey: '',
      publicKey: '',
      homeSpaceId: FakeTraderaService.homeId,
    ));
    return d;
  }

  Future<void> seedSession() async {
    SharedPreferences.setMockInitialValues({
      'tradera.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
              '"token":"x","private_key":"","public_key":"",'
              '"home_space_id":"00000000000000010000000000000002"}',
    });
  }

  Future<List<String>> capture(WidgetTester tester, Size size, String name,
      Future<void> Function() build) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final culprit =
          RegExp(r'The relevant error-causing widget was:\s*\n\s*(.*)\n\s*(.*)')
              .firstMatch(details.toString());
      errors.add('${details.exceptionAsString().split('\n').first}'
          '${culprit == null ? '' : ' @ ${culprit.group(1)} ${culprit.group(2)}'}');
    };
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    try {
      await build();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (shots != null) {
        await expectLater(find.byType(MaterialApp).first,
            matchesGoldenFile(Uri.file('$shots/$name.png')));
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
    'wallet': (d) => WalletScreen(dependencies: d),
    'market': (d) => MarketScreen(dependencies: d),
    'my_bots': (d) => AgentsScreen(dependencies: d),
    'chats': (d) => ChatsScreen(dependencies: d),
    for (var i = 0; i < 7; i++)
      'account_$i': (d) => AccountHubScreen(dependencies: d, initialIndex: i),
    'project_control': (d) => ProjectControlScreen(
        dependencies: d,
        spaceId: FakeTraderaService.atlasId,
        spaceName: 'Atlas Capital'),
    'space_settings': (d) => Scaffold(
        body: SpaceSettingsPanel(
            dependencies: d,
            space: const Workspace(
                id: FakeTraderaService.atlasId,
                ownerId: 'me',
                name: 'Atlas Capital'))),
    'routines': (d) => Scaffold(
        body: RoutinesPanel(
            dependencies: d,
            spaceId: FakeTraderaService.atlasId,
            roomId: 'room-1',
            roomName: 'General')),
  };

  for (final size in sizes.entries) {
    for (final screen in screens.entries) {
      testWidgets('${size.key} · ${screen.key}', (tester) async {
        final errors = await capture(
            tester, size.value, '${size.key}_${screen.key}', () async {
          await tester.pumpWidget(host(screen.value(deps())));
        });
        expect(errors, isEmpty);
      });
    }

    testWidgets('${size.key} · app flows', (tester) async {
      Future<void> app(String name, [Future<void> Function()? interact]) async {
        await seedSession();
        final errors =
            await capture(tester, size.value, '${size.key}_$name', () async {
          await tester.pumpWidget(TraderaApp(
              dependencies: AppDependencies.withService(FakeTraderaService())));
          await tester.pumpAndSettle();
          await interact?.call();
          await tester.pumpAndSettle();
        });
        expect(errors, isEmpty, reason: name);
      }

      await app('feed');
      await app(
          'profile_menu', () => tester.tap(find.byType(CircleAvatar).first));
      await app('workspace', () async {
        await tester.tap(find.text('TRADERA'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Atlas Capital'));
      });
      SharedPreferences.setMockInitialValues({});
      final errors =
          await capture(tester, size.value, '${size.key}_auth', () async {
        await tester.pumpWidget(TraderaApp(
            dependencies: AppDependencies.withService(FakeTraderaService())));
        await tester.pumpAndSettle();
      });
      expect(errors, isEmpty, reason: 'auth');
    });
  }
}
