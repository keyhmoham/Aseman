import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/features/account/presentation/account_hub_content.dart';
import 'package:tradera/src/features/account/presentation/account_panel.dart';
import 'package:tradera/src/features/admin/presentation/admin_page_content.dart';
import 'package:tradera/src/features/admin/presentation/admin_widgets.dart';
import 'package:tradera/src/features/home/presentation/project_control_content.dart';

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
          'finance.ledger_list': {
            'entries': [
              {'kind': 'credit', 'description': 'Top-up', 'amount': 500}
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

    await pumpWide(
      tester,
      ProjectControlContent(
        area: 'Files',
        spaceId: 'space-1',
        results: const {
          'spaces.sandbox_files': {
            'files': [
              {'name': 'README.md', 'path': '/workspace/README.md', 'size': 42}
            ]
          },
          'spaces.file_list': {'files': <Map<String, dynamic>>[]},
        },
        onAction: (_, __, ___) async {},
      ),
    );
    expect(find.text('Search workspace files'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('New folder'), findsOneWidget);
    expect(find.text('Actions'), findsOneWidget);
  });
}
