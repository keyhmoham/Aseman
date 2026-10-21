import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/features/admin/presentation/admin_forms.dart';
import 'package:aseman/src/features/admin/presentation/admin_page_content.dart';
import 'package:aseman/src/features/admin/presentation/admin_widgets.dart';

import 'admin_fixtures.dart';

/// Writes screenshots when ADMIN_SHOTS names a directory.
final shots = Platform.environment['ADMIN_SHOTS'];

void main() {
  setUpAll(() async {
    if (shots != null) await loadFonts();
  });

  /// Opens the form for [action] and returns a future of what it submits.
  Future<Future<Map<String, dynamic>?>> open(
    WidgetTester tester,
    String namespace,
    String action,
    Map<String, dynamic> body, {
    Size size = const Size(1280, 1000),
    Map<String, dynamic> lookups = const {},
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Future<Map<String, dynamic>?> result;
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkWith(const Color(0xFF8B7BFF)),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => result = showAdminActionForm(context,
                  namespace: namespace,
                  action: action,
                  initialBody: body,
                  lookup: (ns, a, _) async => lookups['$ns.$a']),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (shots == null) return;
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile(Uri.file('$shots/form_$name.png')));
  }

  testWidgets('grant credits picks an amount, reason and expiry without typing',
      (tester) async {
    final result = await open(tester, 'finance', 'wallet_mint',
        {'target': 'acct-1', '_name': 'Ada Lovelace'});
    expect(find.text('Grant credits'), findsOneWidget);
    // No raw RFC 3339 field: expiry is chosen with chips.
    expect(find.text('Never'), findsOneWidget);
    for (final chip in ['1000', '30 days']) {
      final finder = find.widgetWithText(ChoiceChip, chip);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
    }
    await tester.pump();
    await shot(tester, 'grant');
    await tester.tap(find.text('Grant 1000 credits'));
    await tester.pumpAndSettle();
    final body = await result;
    expect(body!['target'], 'acct-1');
    expect(body['amount'], 1000 * 10000);
    expect(body['reason'], 'Support credit');
    expect(DateTime.parse(body['expires_at'] as String).isUtc, isTrue);
    expect(body.containsKey('_name'), isFalse);
  });

  testWidgets('editing a user sends only what changed', (tester) async {
    final result = await open(tester, 'users', 'account_update', {
      'account': 'acct-1',
      'handle': 'ada',
      'email': 'ada@example.com',
      'role': null,
      'status': 'active',
      'profile': {'firstName': 'Ada', 'lastName': 'Lovelace'},
    });
    expect(find.byType(SegmentedButton<String>), findsWidgets);
    await tester.tap(find.text('Administrator'));
    await tester.pump();
    await shot(tester, 'user');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(await result, {'account': 'acct-1', 'role': 'admin'});
  });

  testWidgets('a budget can be removed with the No limit chip', (tester) async {
    final result = await open(tester, 'finance', 'budget_set',
        {'space': 'space-1', '_cap': 50000000, '_spent': 20000000});
    await tester.tap(find.widgetWithText(ChoiceChip, 'No limit'));
    await tester.pump();
    await tester.tap(find.text('Remove limit'));
    await tester.pumpAndSettle();
    expect(await result, {'space': 'space-1', 'cap': 0});
  });

  testWidgets('marking a payout paid needs the transfer reference',
      (tester) async {
    final result = await open(tester, 'finance', 'payout_resolve', {
      'payout_id': 'p1',
      'status': 'paid',
      '_amount': 500000,
      '_name': 'ada'
    });
    final button = find.widgetWithText(FilledButton, 'Mark paid');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField).first, 'BANK-42');
    await tester.pump();
    await shot(tester, 'payout');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(await result, {
      'payout_id': 'p1',
      'resolution_id': 'p1-paid',
      'status': 'paid',
      'provider_reference': 'BANK-42',
    });
  });

  testWidgets('deleting asks for an explicit acknowledgement', (tester) async {
    final result = await open(tester, 'users', 'account_delete',
        {'account': 'acct-1', '_name': 'Ada Lovelace'});
    expect(find.text('Delete Ada Lovelace?'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, 'Delete user');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await shot(tester, 'delete');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(await result, {'account': 'acct-1'});
  });

  testWidgets('a new agent picks its model from the configured providers',
      (tester) async {
    final fixtures = adminFixtures();
    final result = await open(tester, 'bots', 'bot_create', {
      'kind': 'agent'
    }, lookups: {
      'llm.llm_providers_list': fixtures['llm.llm_providers_list']
    });
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Research analyst');
    await tester.tap(find.widgetWithText(
        ChoiceChip, 'OpenAI production account with a long name'));
    await tester.pump();
    // Decision and embedding models are not offered as an agent backbone.
    expect(find.widgetWithText(ChoiceChip, 'gpt-5.4-mini'), findsNothing);
    for (final chip in ['GPT-5.4', r'$0.05']) {
      final finder = find.widgetWithText(ChoiceChip, chip);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
    }
    await tester.pump();
    await shot(tester, 'agent');
    await tester.ensureVisible(find.text('Create agent'));
    await tester.tap(find.text('Create agent'));
    await tester.pumpAndSettle();
    expect(await result, {
      'kind': 'agent',
      'name': 'Research analyst',
      'provider': 'prov-openai',
      'model': 'gpt-5.4',
      'cost': {'per_minute': 50000},
    });
  });

  testWidgets('MCP headers are edited as name and value rows', (tester) async {
    final result = await open(tester, 'tools', 'mcp_register', const {},
        size: const Size(390, 844));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Market data');
    await tester.enterText(find.widgetWithText(TextFormField, 'Server URL'),
        'https://mcp.example.com/sse');
    await tester.ensureVisible(find.text('Add header'));
    await tester.tap(find.text('Add header'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Header'), 'X-Key');
    await tester.enterText(find.widgetWithText(TextField, 'Value'), 'secret');
    await tester.pump();
    await shot(tester, 'mcp_phone');
    await tester.ensureVisible(find.text('Add app'));
    await tester.tap(find.text('Add app'));
    await tester.pumpAndSettle();
    expect(await result, {
      'name': 'Market data',
      'url': 'https://mcp.example.com/sse',
      'auth': '',
      'headers': {'X-Key': 'secret'},
      'listed': true,
    });
  });

  testWidgets('the finance period chips re-query the overview', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final queries = <String, Map<String, dynamic>>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AdminPageContent(
          page: 'Finance · Overview',
          loading: false,
          results: {'finance.overview': adminFixtures()['finance.overview']},
          onRefresh: () async {},
          onAction: (_, __, ___) async {},
          onDirectAction: (_, __, ___) async => null,
          onNavigate: (_) {},
          onQuery: (call, body) async => queries[call] = body,
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Last 30 days'));
    await tester.pump();
    final since =
        DateTime.parse(queries['finance.overview']!['since'] as String);
    expect(DateTime.now().difference(since).inDays, 30);
    await tester.tap(find.text('All time'));
    await tester.pump();
    expect(queries['finance.overview'], isEmpty);
    expect(find.byType(AdminDonutChart), findsOneWidget);
  });

  /// Pumps one admin page with [results] and records its direct actions.
  Future<List<(String, Map<String, dynamic>)>> page(
      WidgetTester tester, String name, Map<String, dynamic> results) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <(String, Map<String, dynamic>)>[];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkWith(const Color(0xFF8B7BFF)),
      home: Scaffold(
        body: AdminPageContent(
          page: name,
          loading: false,
          results: results,
          onRefresh: () async {},
          onAction: (_, __, ___) async {},
          onDirectAction: (ns, action, body) async {
            calls.add(('$ns.$action', body));
            return null;
          },
          onNavigate: (_) {},
        ),
      ),
    ));
    await tester.pump();
    return calls;
  }

  testWidgets('editing an imported model keeps what the import recorded',
      (tester) async {
    final calls = await page(tester, 'Models', {
      'llm.llm_providers_list': {
        'providers': [
          {
            'id': 'prov-vercel',
            'name': 'Vercel',
            'kind': 'vercel',
            'enabled': true,
            'models': [
              {
                'id': 'flux-pro',
                'name': 'Flux',
                'input_price': 0,
                'output_price': 0,
                'capabilities': ['image'],
                'units': {'image': 40000},
                'base_units': {'image': 33333},
                'source': 'vercel',
                'markup': 20,
                'tags': ['image-generation'],
              }
            ],
          }
        ]
      }
    });
    expect(find.textContaining(r'$0.04 / image'), findsOneWidget);
    expect(find.text('Import from Vercel'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit model'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Display name (optional)'), 'Flux Pro');
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    var model = ((calls.last.$2['models'] as List).single as Map);
    expect(calls.last.$1, 'llm.llm_provider_set');
    expect(model['name'], 'Flux Pro');
    expect(model['units'], {'image': 40000.0});
    expect(model['source'], 'vercel');
    expect(model['markup'], 20, reason: 'the price did not change');
    expect(model['base_units'], {'image': 33333});
    expect(model['tags'], ['image-generation']);

    // A price typed by hand is no longer Vercel's price plus the markup.
    await tester.tap(find.byTooltip('Edit model'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, r'$ per image'), '0.05');
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    model = ((calls.last.$2['models'] as List).single as Map);
    expect(model['units'], {'image': 50000.0});
    expect(model['source'], 'vercel');
    expect(model.containsKey('markup'), isFalse);
    expect(model.containsKey('base_units'), isFalse);
  });

  testWidgets('saving prices keeps the developer storage price',
      (tester) async {
    final saved = <Map<String, dynamic>>[];
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AdminPageContent(
          page: 'Settings · Pricing',
          loading: false,
          results: {'settings.get': adminFixtures()['settings.get']},
          onRefresh: () async {},
          onAction: (_, __, ___) async {},
          onDirectAction: (ns, action, body) async {
            saved.add(body);
            return null;
          },
          onNavigate: (_) {},
        ),
      ),
    ));
    await tester.pump();
    // Change any rate so the save bar appears, then save.
    await tester.ensureVisible(find.text('Free'));
    await tester.tap(find.text('Free'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((saved.single['pricing'] as Map)['storage_gb_month'], 0);
  });

  testWidgets('a chat report is resolved from its evidence', (tester) async {
    final calls = await page(tester, 'Chat reports', {
      'spaces.admin_chat_reports': {
        'open': 1,
        'reports': [
          {
            'id': 'rep-1',
            'status': 'open',
            'reason': 'scam',
            'kind': 'message',
            'message_id': 'm2',
            'direct': true,
            'created_at': '2026-10-19T10:00:00Z',
            'reporter': {'handle': 'alice'},
            'accused': {'handle': 'bob'},
            'evidence': [
              {
                'id': 'm1',
                'sender': {'handle': 'alice'},
                'body': 'hi bob'
              },
              {
                'id': 'm2',
                'sender': {'handle': 'bob'},
                'body': 'send me your password'
              },
            ],
          }
        ],
      }
    });
    await tester.tap(find.textContaining('SCAM'));
    await tester.pumpAndSettle();
    expect(find.text('send me your password'), findsOneWidget);
    await tester.tap(find.text('Mark resolved'));
    await tester.pump();
    expect(calls.single.$1, 'spaces.admin_chat_report_resolve');
    expect(calls.single.$2, {'id': 'rep-1', 'status': 'resolved'});
  });
}
