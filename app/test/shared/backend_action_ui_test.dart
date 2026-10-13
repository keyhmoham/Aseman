import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/shared/widgets/backend_action_ui.dart';

void main() {
  testWidgets('action form validates and converts typed fields',
      (tester) async {
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return FilledButton(
          onPressed: () async {
            submitted = await showBackendActionForm(
              context,
              namespace: 'finance',
              action: 'wallet_mint',
            );
          },
          child: const Text('Open'),
        );
      }),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Grant credits'), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'account-1');
    await tester.enterText(fields.at(1), '12');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(submitted, {
      'target': 'account-1',
      'amount': 120000,
    });
  });

  testWidgets('destructive actions display an explicit confirmation warning',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return FilledButton(
          onPressed: () => showBackendActionForm(
            context,
            namespace: 'spaces',
            action: 'space_delete',
          ),
          child: const Text('Open'),
        );
      }),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
        find.text('This action can remove or disable data.'), findsOneWidget);
    expect(find.text('Confirm'), findsOneWidget);
  });

  testWidgets('record lists render as structured tables', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: BackendResultView(results: {
          'users.accounts_list': {
            'accounts': [
              {'handle': 'maya', 'role': 'admin'},
              {'handle': 'alex', 'role': 'user'},
            ],
          },
        }),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('accounts'));
    await tester.pumpAndSettle();

    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('maya'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
  });
}
