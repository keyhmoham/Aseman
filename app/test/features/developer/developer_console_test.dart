import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/developer/presentation/developer_console.dart';

import '../../fake_aseman_service.dart';

class _Service extends FakeAsemanService {
  final calls = <String>[];
  final keys = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> developer(String action,
      [Map<String, dynamic> body = const {}]) async {
    calls.add(action);
    switch (action) {
      case 'orgs_list':
        return {
          'orgs': [
            {'id': 'personal', 'name': 'Personal', 'role': 'owner'}
          ],
          'invites': [
            {'org': 'org-1', 'name': 'Acme', 'role': 'developer', 'invitedBy': 'ada'}
          ],
        };
      case 'wallet_get':
        return {'balance': 12500000, 'entries': <dynamic>[]};
      case 'settings_get':
        return {'accountMonthlyCap': 0, 'spentMonth': 1500000};
      case 'usage_report':
        return {
          'total': {'spend': 3000000, 'requests': 1200, 'errors': 3},
          'days': <dynamic>[],
          'byModel': [
            {'name': 'gpt-5.4', 'spend': 2000000, 'requests': 900, 'tokens': 50000}
          ],
        };
      case 'keys_list':
        return {'keys': keys};
      case 'key_create':
        keys.add({
          'id': 'k1',
          'name': (body['input'] as Map)['name'],
          'prefix': 'dk_live_ab',
          'last4': 'wxyz',
          'status': 'active',
          'spentMonth': 0,
          'requests': 0,
          'lastUsedAt': '',
        });
        return {'key': keys.last, 'secret': 'dk_live_abcdefwxyz'};
      case 'platform_catalog':
        return {
          'object': 'list',
          'base': '/v1/platform',
          'namespaces': [
            {
              'name': 'spaces',
              'actions': [
                {
                  'name': 'message_send',
                  'summary': 'Send a message',
                  'path': '/v1/platform/spaces/message_send',
                }
              ],
            }
          ],
        };
    }
    return const {};
  }
}

void main() {
  testWidgets('the console shows money and makes a key shown once',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Service();
    await tester.pumpWidget(MaterialApp(home: DeveloperConsole(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('ada invited you to Acme as developer.'), findsOneWidget);
    expect(find.text(r'$12.50'), findsOneWidget);
    expect(find.textContaining('1.2K requests'), findsOneWidget);

    await tester.tap(find.text('API keys'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No keys yet'), findsOneWidget);
    await tester.tap(find.text('New key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Server');
    await tester.tap(find.text('Create key'));
    await tester.pumpAndSettle();
    expect(find.text('Copy your key now'), findsOneWidget);
    expect(find.text('dk_live_abcdefwxyz'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Server'), findsOneWidget);
    expect(service.calls, contains('key_create'));
  });
}
