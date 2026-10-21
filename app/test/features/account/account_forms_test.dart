import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/features/account/presentation/account_forms.dart';

void main() {
  Future<Future<Map<String, dynamic>?>> open(
      WidgetTester tester, String namespace, String action,
      [Map<String, dynamic> body = const {}]) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Future<Map<String, dynamic>?> result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkWith(const Color(0xFF8B7BFF)),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => result = showAccountActionForm(context,
                  namespace: namespace, action: action, initialBody: body),
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

  Future<void> submit(WidgetTester tester, String label) async {
    final button = find.widgetWithText(FilledButton, label);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('payout request picks method and amount without raw JSON',
      (tester) async {
    final result = await open(
        tester, 'finance', 'payout_request', {'_available': 50000000});
    expect(find.text('Request a payout'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '2500'));
    await tester.tap(find.text('PayPal'));
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'PayPal email'), 'ada@example.com');
    await submit(tester, 'Request 2500 credits');
    final body = (await result)!;
    expect(body['amount'], 2500 * 10000);
    expect(body['method'], 'paypal');
    expect(body['destination'], {'email': 'ada@example.com'});
    expect('${body['request_id']}', startsWith('payout-'));
  });

  testWidgets('a bank payout validates the IBAN', (tester) async {
    final result = await open(
        tester, 'finance', 'payout_request', {'_available': 10000000});
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Account holder'), 'Ada L');
    await tester.enterText(find.widgetWithText(TextFormField, 'IBAN'), 'nope');
    await submit(tester, 'Request 1000 credits');
    expect(find.text('Enter a valid IBAN'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'IBAN'),
        'de89 3704 0044 0532 0130 00');
    await submit(tester, 'Request 1000 credits');
    expect((await result)!['destination'],
        {'name': 'Ada L', 'iban': 'DE89370400440532013000'});
  });

  testWidgets('password change asks for the current one', (tester) async {
    final result = await open(
        tester, 'auth', 'profile_update', const {'_mode': 'password'});
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Current password'), 'old-pass');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'New password'), 'n3w-Passw0rd!');
    await submit(tester, 'Change password');
    expect(await result,
        {'current_password': 'old-pass', 'password': 'n3w-Passw0rd!'});
  });

  testWidgets('profile edits send only the changed keys', (tester) async {
    final result = await open(tester, 'auth', 'profile_update', {
      '_mode': 'profile',
      'profile': {'firstName': 'Ada', 'lastName': 'Lovelace', 'bio': 'Hi'},
    });
    await tester.enterText(find.widgetWithText(TextField, 'Bio'), 'Quant');
    await tester.tap(find.text('Available for hire'));
    await tester.pump();
    await submit(tester, 'Save profile');
    expect(await result, {
      'profile': {'bio': 'Quant', 'hireable': true}
    });
  });
}
