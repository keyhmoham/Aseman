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

    // The amount is picked with a preset chip, not typed.
    await tester.enterText(find.byType(TextFormField).first, 'account-1');
    await tester.tap(find.widgetWithText(ChoiceChip, '500'));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(submitted, {
      'target': 'account-1',
      'amount': 5000000,
    });
  });

  testWidgets('supplied identifiers are passed through, not shown',
      (tester) async {
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return FilledButton(
          onPressed: () async {
            submitted = await showBackendActionForm(
              context,
              namespace: 'routines',
              action: 'create',
              initialBody: const {'space': 'space-1'},
            );
          },
          child: const Text('Open'),
        );
      }),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('space-1'), findsNothing);
    expect(find.text('Project'), findsNothing);
    // Choices are chips, intervals are durations.
    await tester.tap(find.text('Periodic'));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Task'), 'Summarise the news');
    await tester.ensureVisible(find.text('1 hour').last);
    await tester.tap(find.text('1 hour').last);
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Create'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(submitted, {
      'space': 'space-1',
      'type': 'periodic',
      'task': 'Summarise the news',
      'interval_sec': 3600,
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
    // The confirm button waits for the acknowledgement.
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
            .onPressed,
        isNull);
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
