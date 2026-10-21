import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/account/presentation/account_hub_content.dart';
import 'package:aseman/src/features/account/presentation/account_panel.dart';
import 'package:aseman/src/features/admin/presentation/admin_page_content.dart';
import 'package:aseman/src/features/admin/presentation/admin_widgets.dart';

void main() {
  Future<void> pumpWide(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(body: child),
    ));
    await tester.pump();
  }

  testWidgets('admin users is a searchable operational table', (tester) async {
    await pumpWide(
      tester,
      AdminPageContent(
        page: 'Users',
        loading: false,
        results: const {
          'users.accounts_list': {
            'accounts': [
              {
                'id': 'user-123456789',
                'handle': 'ada',
                'email': 'ada@example.com',
                'status': 'active',
                'balance': 250,
                'profile': {'firstName': 'Ada', 'lastName': 'Lovelace'},
              }
            ]
          },
          'admin.admins_list': {'admins': <Map<String, dynamic>>[]},
        },
        onRefresh: () async {},
        onAction: (_, __, ___) async {},
        onDirectAction: (_, __, ___) async => null,
        onNavigate: (_) {},
      ),
    );

    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('Search name, handle, email, or user id'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AdminDataTable),
            matching: find.text('Ada Lovelace')),
        findsOneWidget);
    // Status filters are chips with counts, not a dropdown.
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'Everyone'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Balance'), findsOneWidget);
  });

  testWidgets('projects choose the space every platform admin joins',
      (tester) async {
    final calls = <String>[];
    Map<String, dynamic> project(String id, String name) => {
          'id': id,
          'name': name,
          'owner': {'handle': 'ada'},
          'created_at': '2026-01-01T00:00:00Z',
        };
    await pumpWide(
      tester,
      AdminPageContent(
        page: 'Projects',
        loading: false,
        results: {
          'spaces.space_list_all': {
            'spaces': [
              project('space-1', 'Operations'),
              project('space-2', 'Admins HQ'),
              {...project('space-3', 'Direct chat'), 'direct_key': 'a:b'},
            ]
          },
          'spaces.admins_space_get': {
            'space': {'id': 'space-1', 'name': 'Operations'}
          },
          'admin.admins_list': {
            'admins': [
              {'id': 'a1', 'handle': 'ada'},
              {'id': 'a2', 'handle': 'bob'},
            ]
          },
        },
        onRefresh: () async {},
        onAction: (_, __, ___) async {},
        onDirectAction: (namespace, action, body) async {
          calls.add('$namespace.$action ${body['space']}');
          return null;
        },
        onNavigate: (_) {},
      ),
    );

    expect(find.text('Platform admins space'), findsOneWidget);
    expect(find.textContaining('2 admins are members'), findsOneWidget);
    expect(find.textContaining('Admins space · '), findsOneWidget);

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    final picker = find.byType(AlertDialog);
    expect(find.text('Choose the admins space'), findsOneWidget);
    // Direct conversations cannot take members.
    expect(find.descendant(of: picker, matching: find.text('Direct chat')),
        findsNothing);
    await tester
        .tap(find.descendant(of: picker, matching: find.text('Admins HQ')));
    await tester.pumpAndSettle();
    expect(calls, ['spaces.admins_space_set space-2']);
  });

  testWidgets('finance overview presents KPIs and visual breakdown',
      (tester) async {
    await pumpWide(
      tester,
      AdminPageContent(
        page: 'Finance · Overview',
        loading: false,
        results: const {
          'finance.overview': {
            'income': {'credits_sold': 10000, 'purchases': 4},
            'charged': {
              'total': 8000,
              'compute': 2000,
              'tools': 1000,
              'llm': 3000,
              'agent_time': 2000,
            },
            'paid_out': {'creators': 3000},
            'kept': 5000,
            'held_by_users': 2000,
          },
          'finance.reconcile': {
            'ok': true,
            'checked': 2,
            'issues': <Map<String, dynamic>>[]
          },
        },
        onRefresh: () async {},
        onAction: (_, __, ___) async {},
        onDirectAction: (_, __, ___) async => null,
        onNavigate: (_) {},
      ),
    );

    expect(find.text('Income'), findsOneWidget);
    expect(find.text('Customer spend'), findsOneWidget);
    expect(find.text('What customers spent it on'), findsOneWidget);
    expect(find.byType(AdminDonutChart), findsOneWidget);
    expect(find.text('LLM tokens'), findsOneWidget);
    expect(find.textContaining('Balanced'), findsOneWidget);
  });

  testWidgets('account billing and project files use dedicated controls',
      (tester) async {
    await pumpWide(
      tester,
      AccountHubContent(
        area: AccountArea.wallet,
        results: const {
          'finance.wallet_get': {'balance': 500, 'locked': 10},
          'finance.account': {
            'transactions': [
              {'type': 'transfer', 'description': 'Top-up', 'amount': 500},
              {
                'type': 'mint',
                'description': 'Welcome credits · expires 2 Jan 2027',
                'base_description': 'Welcome credits',
                'amount': 300,
                'expires_at': '2027-01-02T00:00:00Z',
                'grant_status': 'active',
              },
              {
                'type': 'mint',
                'description': 'Promo · expired 1 Feb 2026',
                'amount': 100,
                'expires_at': '2026-02-01T00:00:00Z',
                'grant_status': 'expired',
              },
            ]
          },
          'finance.purchases_mine': {'purchases': <Map<String, dynamic>>[]},
        },
        onAction: (_, __, ___) async {},
        onNotifications: (_) {},
        notificationsSupported: false,
      ),
    );
    expect(find.text('Available balance'), findsOneWidget);
    expect(find.text('Add credits'), findsOneWidget);
    expect(find.text('WALLET ACTIVITY'), findsOneWidget);
    expect(find.text('Top-up'), findsOneWidget);
    // Granted credits say when they lapse; lapsed ones say so.
    expect(find.text('Credits that expire'), findsOneWidget);
    expect(find.textContaining('Welcome credits'), findsNWidgets(2));
    expect(find.text('Promo · expired 1 Feb 2026'), findsOneWidget);
  });
}
