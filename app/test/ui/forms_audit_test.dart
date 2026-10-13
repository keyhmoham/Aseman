import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/core/network/session_store.dart';
import 'package:tradera/src/core/settings/app_settings.dart';
import 'package:tradera/src/core/theme/app_theme.dart';
import 'package:tradera/src/data/models/llm_provider.dart';
import 'package:tradera/src/features/account/presentation/account_forms.dart';
import 'package:tradera/src/features/agents/presentation/agent_create_form.dart';
import 'package:tradera/src/features/home/presentation/widgets/routines_panel.dart';
import 'package:tradera/src/features/market/presentation/market_screen.dart';
import 'package:tradera/src/features/wallet/presentation/wallet_screen.dart';
import 'package:tradera/src/shared/widgets/backend_action_ui.dart';

import '../fake_tradera_service.dart';
import '../features/admin/admin_fixtures.dart' show loadFonts;

/// Opens each form outside the admin console at phone and desktop sizes,
/// fails on layout errors, and writes screenshots when UI_SHOTS is set.
final shots = Platform.environment['UI_SHOTS'];

const sizes = {'phone': Size(390, 844), 'desktop': Size(1280, 900)};

const _provider = LlmProvider(
  id: 'p-openai',
  name: 'OpenAI',
  kind: 'openai',
  baseUrl: '',
  isDefault: true,
  hasKey: true,
  keyPreview: 'sk-…',
  models: [
    LlmModel(id: 'gpt-5.4', inputPrice: 1000, outputPrice: 4000),
    LlmModel(id: 'gpt-5.4-mini', inputPrice: 100, outputPrice: 400),
  ],
);

void main() {
  setUpAll(() async {
    if (shots != null) await loadFonts();
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

  final forms = <String,
      (Widget Function(AppDependencies), Future<void> Function(WidgetTester))>{
    'agent_create': (
      (d) => Builder(
          builder: (context) => FilledButton(
              onPressed: () => showCreateBotForm(context,
                  loadLlmCatalog: () async => const [_provider]),
              child: const Text('open'))),
      (t) => t.tap(find.text('open')),
    ),
    'routine_new': (
      (d) => RoutinesPanel(
          dependencies: d,
          spaceId: FakeTraderaService.atlasId,
          roomId: 'room-1',
          roomName: 'General'),
      (t) => t.tap(find.text('New routine')),
    ),
    'market_publish': (
      (d) => MarketScreen(dependencies: d),
      (t) => t.tap(find.text('Publish')),
    ),
    'wallet_send': (
      (d) => WalletScreen(dependencies: d),
      (t) => t.tap(find.byTooltip('Transfer')),
    ),
    'payout_request': (
      (d) => Builder(
          builder: (context) => FilledButton(
              onPressed: () => showAccountActionForm(context,
                  namespace: 'finance',
                  action: 'payout_request',
                  initialBody: const {'_available': 25000000}),
              child: const Text('open'))),
      (t) => t.tap(find.text('open')),
    ),
    'generic_routine': (
      (d) => Builder(
          builder: (context) => FilledButton(
              onPressed: () => showBackendActionForm(context,
                  namespace: 'routines',
                  action: 'create',
                  initialBody: const {'space': 'space-1'}),
              child: const Text('open'))),
      (t) => t.tap(find.text('open')),
    ),
  };

  for (final size in sizes.entries) {
    for (final form in forms.entries) {
      testWidgets('${size.key} · ${form.key}', (tester) async {
        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) {
          final where = RegExp(r'file:///\S+')
              .allMatches(details.toString())
              .map((m) => m.group(0)!.split('/lib/').last)
              .take(2)
              .join(' < ');
          errors
              .add('${details.exceptionAsString().split('\n').first} @ $where');
        };
        tester.view.physicalSize = size.value;
        tester.view.devicePixelRatio = 1;
        try {
          await tester.pumpWidget(AppSettingsScope(
            controller: AppSettingsController(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.darkWith(const Color(0xFF8B7BFF)),
              home: Scaffold(body: Center(child: form.value.$1(deps()))),
            ),
          ));
          await tester.pumpAndSettle();
          await form.value.$2(tester);
          await tester.pumpAndSettle();
          if (shots != null) {
            await expectLater(
                find.byType(MaterialApp),
                matchesGoldenFile(
                    Uri.file('$shots/form_${size.key}_${form.key}.png')));
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          FlutterError.onError = previous;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
        expect(errors, isEmpty);
      });
    }
  }
}
