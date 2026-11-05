import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/developer/presentation/developer_console.dart';

import '../../fake_aseman_service.dart';

class _Service extends FakeAsemanService {
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  Map<String, dynamic>? frontend;
  final keys = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> developer(String action,
      [Map<String, dynamic> body = const {}]) async {
    calls.add(action);
    bodies[action] = body;
    switch (action) {
      case 'platform_get':
        return {
          'platform': {
            'id': 'pf1',
            'slug': 'acme',
            'name': 'Acme',
            'mainAccess': false,
            'frontend': frontend,
          }
        };
      case 'platform_stats':
        return {'users': 0, 'spaces': 1, 'bots': 2};
      case 'platform_users':
        return {'users': <dynamic>[]};
      case 'platform_frontend_apps':
        return {
          'apps': [
            {
              'proxy_id': 'p1',
              'title': 'Store',
              'ui': 'elpian',
              'audience': 'platform',
              'space_name': 'Studio',
              'wiring': {
                'agents': [
                  {'id': 'a1', 'name': 'Advisor'}
                ],
                'apps': <dynamic>[],
              },
            }
          ]
        };
      case 'platform_frontend_publish':
        frontend = {
          'title': 'Store',
          'ui': 'elpian',
          'entry': 'elpian/app.js',
          'url': '/v1/platforms/acme/app/',
          'wiring': {
            'agents': [
              {'id': 'a1', 'name': 'Advisor'}
            ],
            'apps': <dynamic>[],
          },
        };
        return {'platform': <String, dynamic>{}};
      case 'platform_frontend_unpublish':
        frontend = null;
        return {'platform': <String, dynamic>{}};
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

  testWidgets('an owner publishes an agent-built app as the platform frontend',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Service();
    await tester.pumpWidget(MaterialApp(home: DeveloperConsole(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sub-platform').first);
    await tester.pumpAndSettle();
    expect(find.text('Frontend'), findsOneWidget);

    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();
    expect(find.text('Built for platforms'), findsOneWidget);
    expect(find.textContaining('uses Advisor'), findsOneWidget);
    await tester.tap(find.text('Store'));
    await tester.pumpAndSettle();
    // The confirmation's button: the last "Publish" on screen.
    await tester.tap(find.text('Publish').last);
    await tester.pumpAndSettle();
    expect(service.bodies['platform_frontend_publish']!['proxy'], 'p1');
    expect(find.text('/v1/platforms/acme/app/'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Advisor'), findsOneWidget);

    await tester.tap(find.byTooltip('Take down'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take down').last);
    await tester.pumpAndSettle();
    expect(service.calls, contains('platform_frontend_unpublish'));
    expect(find.text('/v1/platforms/acme/app/'), findsNothing);
  });
}
