import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tradera/src/app.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/data/models/bot.dart';
import 'package:tradera/src/features/home/presentation/widgets/space_facility_tabs.dart';

import '../../fake_tradera_service.dart';

/// Answers the facility tabs' actions and records what they sent.
class _Service extends FakeTraderaService {
  final calls = <String>[];
  final written = <String, String>{};

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
  }) async {
    final call = '$namespace.$action';
    if (call == 'spaces.computer') {
      return {
        'machine': {
          'state': 'awake',
          'provider': 'nomad',
          'id': 'vm-7',
          'cpu': 2,
          'memory_mb': 4096,
        },
      };
    }
    if (call == 'spaces.sandbox_files') {
      final path = '${body['path']}';
      calls.add('${body['operation']} $path');
      if (body['operation'] == 'write') {
        written[path] = '${body['content']}';
        return const {};
      }
      return {'content': path == 'AGENTS.md' ? '# Team notes' : '# Own notes'};
    }
    if (call == 'spaces.proxy_list') {
      return {
        'proxies': [
          {'id': 'p1', 'port': 3000, 'url': 'https://p1.example/'},
        ],
      };
    }
    return super.invokeAction(namespace, action, body: body, timeout: timeout);
  }

  @override
  Future<List<Bot>> fetchSpaceBots(String spaceId) async => [
    ...await super.fetchSpaceBots(spaceId),
    for (final (id, name) in [('gh', 'GitHub'), ('ln', 'Linear')])
      Bot(
        id: id,
        ownerId: 'me',
        accountId: 'acct-$id',
        name: name,
        kind: 'tool',
        vmType: 'mcp',
        status: 'running',
      ),
  ];

  @override
  Future<Map<String, ({String auth, bool connected, String name})>>
  toolConnections(String spaceId) async => const {
    'gh': (auth: 'user', connected: false, name: 'GitHub'),
    'ln': (auth: 'user', connected: true, name: 'Linear'),
  };
}

void main() {
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAllTestValues(),
  );

  Future<void> pumpTab(WidgetTester tester, Widget tab) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(width: 210, height: 600, child: tab)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the computer tab shows the machine and its controls', (
    tester,
  ) async {
    await pumpTab(
      tester,
      SpaceComputerTab(
        dependencies: AppDependencies.withService(_Service()),
        spaceId: FakeTraderaService.atlasId,
      ),
    );
    expect(find.text('Computer awake'), findsOneWidget);
    expect(find.text('nomad · vm-7'), findsOneWidget);
    expect(find.text('Wake / keep alive'), findsOneWidget);
    expect(find.text('Forget logins'), findsOneWidget);
    expect(find.text('4.0 GB'), findsOneWidget);
  });

  testWidgets('the memory tab edits the shared and each agent\'s notes', (
    tester,
  ) async {
    final service = _Service();
    await pumpTab(
      tester,
      SpaceMemoryTab(
        dependencies: AppDependencies.withService(service),
        spaceId: FakeTraderaService.atlasId,
        agents: await service
            .fetchSpaceBots(FakeTraderaService.atlasId)
            .then((b) => b.where((x) => x.isAgent).toList()),
      ),
    );
    expect(find.text('# Team notes'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '# Decided');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.written['AGENTS.md'], '# Decided');

    await tester.tap(find.text('Shared'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SignalBot').last);
    await tester.pumpAndSettle();
    expect(service.calls.last, 'read .tradera/agents/agent-1/AGENTS.md');
    expect(find.text('# Own notes'), findsOneWidget);
  });

  testWidgets('the previews tab lists published ports', (tester) async {
    await pumpTab(
      tester,
      SpacePreviewsTab(
        dependencies: AppDependencies.withService(_Service()),
        spaceId: FakeTraderaService.atlasId,
      ),
    );
    expect(find.text('Publish port'), findsOneWidget);
    expect(find.text('Port 3000'), findsOneWidget);
    expect(find.text('https://p1.example/'), findsOneWidget);
  });

  testWidgets('the space\'s left panel holds its facilities and app sign-ins', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'tradera.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
          '"token":"x","private_key":"","public_key":"",'
          '"home_space_id":"00000000000000010000000000000002"}',
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      TraderaApp(dependencies: AppDependencies.withService(_Service())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Apps'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Needs your sign-in'), findsOneWidget);
    expect(find.byTooltip('Connect your account'), findsOneWidget);
    expect(find.byTooltip('Reconnect your account'), findsOneWidget);

    await tester.tap(find.byTooltip('Computer'));
    await tester.pumpAndSettle();
    expect(find.text('Computer awake'), findsOneWidget);
    await tester.tap(find.byTooltip('Memory'));
    await tester.pumpAndSettle();
    expect(find.text('# Team notes'), findsOneWidget);
    await tester.tap(find.byTooltip('Previews'));
    await tester.pumpAndSettle();
    expect(find.text('Port 3000'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
