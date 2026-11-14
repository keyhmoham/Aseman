import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/developer/presentation/developer_console.dart';

import '../../fake_aseman_service.dart';

class _Service extends FakeAsemanService {
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  Map<String, dynamic>? frontend;
  final keys = <Map<String, dynamic>>[];
  final runs = <Map<String, dynamic>>[];
  int polls = 0;

  Map<String, dynamic> _report(String status) => {
        'status': status,
        'counts': {'created': 2, 'updated': 0, 'unchanged': 1},
        'steps': [
          {'path': 'space', 'action': 'upsert:space', 'status': status == 'running' ? 'running' : 'succeeded', 'operation': 'created'},
          {'path': 'site', 'action': 'sandbox', 'status': status == 'planned' ? 'planned' : 'succeeded'},
        ],
        'outputs': {'preview': '/v1/proxy/p1/'},
        'events': [
          {'level': 'info', 'path': 'site', 'message': 'wrote 1 file(s)'}
        ],
      };

  @override
  Future<Map<String, dynamic>> developer(String action,
      [Map<String, dynamic> body = const {}]) async {
    calls.add(action);
    bodies[action] = body;
    switch (action) {
      case 'platforms_list':
        return {
          'platforms': [
            {
              'id': 'pf1',
              'slug': 'acme',
              'name': 'Acme',
              'mainAccess': false,
              'frontend': frontend,
            },
            {
              'id': 'pf2',
              'slug': 'acme-shop',
              'name': 'Acme Shop',
              'mainAccess': false,
              'frontend': null,
            },
          ]
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
      case 'workflow_validate':
        final doc = '${body['workflow']}';
        return {
          'valid': doc.contains('decillion_workflow'),
          'name': 'my-product',
          'steps': 4,
          'assets': 0,
          'issues': doc.contains('decillion_workflow')
              ? <dynamic>[]
              : [
                  {'severity': 'error', 'path': 'decillion_workflow', 'message': 'must be "1"'}
                ],
          'secrets': [
            {'name': 'API_TOKEN', 'required': true}
          ],
        };
      case 'workflow_plan':
        return {'id': 'r-plan', 'name': 'my-product', 'mode': 'plan', 'status': 'planned', 'report': _report('planned')};
      case 'workflow_run':
        final run = {'id': 'r1', 'name': 'my-product', 'mode': 'run', 'status': 'running', 'started_at': '2026-11-05T10:00:00Z'};
        runs.insert(0, run);
        return run;
      case 'workflow_run_get':
        polls++;
        runs[0] = {...runs[0], 'status': 'succeeded'};
        return {...runs[0], 'report': _report('succeeded')};
      case 'workflow_guide':
        return {'content': '# Writing workflows: a guide for models'};
      case 'workflow_runs':
        return {'runs': runs};
    }
    return const {};
  }

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
    bool anonymous = false,
  }) async {
    if (namespace == 'admin' && action == 'actions_list') {
      calls.add('admin.actions_list');
      return {
        'namespaces': [
          {
            'namespace': 'spaces',
            'actions': [
              {
                'name': 'message_send',
                'summary': 'Send a message',
              }
            ],
          }
        ],
      };
    }
    return super.invokeAction(namespace, action,
        body: body, timeout: timeout, anonymous: anonymous);
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
    // The key is bound to the organization's first platform by default.
    expect((service.bodies['key_create']!['input'] as Map)['platform'], 'pf1');
  });

  testWidgets('an owner publishes an agent-built app as the platform frontend',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Service();
    await tester.pumpWidget(MaterialApp(home: DeveloperConsole(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Platforms').first);
    await tester.pumpAndSettle();
    expect(find.text('Frontend'), findsOneWidget);
    // The organization has two platforms; the first is shown.
    expect(find.widgetWithText(ChoiceChip, 'Acme Shop'), findsOneWidget);
    expect(service.bodies['platform_stats']!['platform'], 'pf1');

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
    expect(service.bodies['platform_frontend_publish']!['platform'], 'pf1');
    expect(find.text('/v1/platforms/acme/app/'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Advisor'), findsOneWidget);

    await tester.tap(find.byTooltip('Take down'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take down').last);
    await tester.pumpAndSettle();
    expect(service.calls, contains('platform_frontend_unpublish'));
    expect(service.bodies['platform_frontend_unpublish']!['platform'], 'pf1');
    expect(find.text('/v1/platforms/acme/app/'), findsNothing);

    // Choosing the other platform shows it.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Acme Shop'));
    await tester.pumpAndSettle();
    expect(service.bodies['platform_stats']!['platform'], 'pf2');
    expect(find.text('@acme-shop'), findsOneWidget);
  });

  testWidgets('a workflow is checked, planned and run, and its run followed',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Service();
    await tester.pumpWidget(MaterialApp(home: DeveloperConsole(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workflows'));
    await tester.pumpAndSettle();
    expect(find.text('No runs yet. Plan or run a workflow above.'), findsOneWidget);

    // Not JSON: told so, and nothing is sent.
    await tester.enterText(find.byKey(const ValueKey('workflow-document')), '{nope');
    await tester.tap(find.text('Validate'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not valid JSON'), findsOneWidget);
    expect(service.calls, isNot(contains('workflow_validate')));

    await tester.tap(find.text('Writing guide'));
    await tester.pumpAndSettle();
    expect(find.text('# Writing workflows: a guide for models'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start from a template'));
    await tester.pumpAndSettle();
    expect(service.calls, contains('workflow_validate'));
    expect(find.textContaining('Valid: my-product'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Secret API_TOKEN (required)'), 'tok-123');
    await tester.enterText(find.byKey(const ValueKey('workflow-inputs')), '{"product": "Acme"}');

    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(service.bodies['workflow_plan']!['inputs'], {'product': 'Acme'});
    expect(service.bodies['workflow_plan']!['secrets'], {'API_TOKEN': 'tok-123'});
    expect(find.text('my-product · planned'), findsOneWidget);
    expect(find.textContaining('2 created'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run').last); // the confirmation
    await tester.pump();
    await tester.pump();
    expect(service.bodies['workflow_run']!['async'], true);
    expect(find.text('my-product · running'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(service.polls, greaterThan(0));
    expect(find.text('my-product · succeeded'), findsOneWidget);
    expect(find.textContaining('/v1/proxy/p1/'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.textContaining('succeeded · run'), findsOneWidget);
  });
}
