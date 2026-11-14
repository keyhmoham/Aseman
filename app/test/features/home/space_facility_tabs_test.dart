import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/features/home/presentation/widgets/space_facility_tabs.dart';

import '../../fake_aseman_service.dart';

import '../../navigation.dart';

/// Answers the facility tabs' actions and records what they sent.
class _Service extends FakeAsemanService {
  final calls = <String>[];
  final written = <String, String>{};
  final operations = <String>[];
  String state = 'awake';

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
    bool anonymous = false,
  }) async {
    final call = '$namespace.$action';
    if (call == 'spaces.computer') {
      final op = '${body['operation']}';
      // Expo polls `status`; record mutating ops only.
      if (op != 'status') operations.add(op);
      if (op == 'provision' || op == 'wake') state = 'awake';
      if (op == 'sleep') state = 'asleep';
      return {
        'state': state,
        'rev': state,
        'status': state == 'awake' ? 'running' : 'stopped',
        'cpu': 2,
        'memory_mb': 4096,
        'disk_mb': 20480,
        'idle_timeout_sec': 120,
      };
    }
    if (call == 'spaces.desktop_install') {
      // The live view needs a real desktop: here it is unavailable.
      throw StateError('no desktop in tests');
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
          {'id': 'p1', 'port': 3000, 'url': '/v1/proxy/p1/', 'kind': 'preview'},
          // The Computer tab's desktop and an installed app are not previews.
          {
            'id': 'p2',
            'port': 6080,
            'title': 'Desktop',
            'url': '/v1/proxy/p2/',
            'kind': 'desktop',
          },
          {
            'id': 'p3',
            'port': 23001,
            'title': 'Tool · Weather',
            'url': '/v1/proxy/p3/',
          },
        ],
      };
    }
    return super.invokeAction(namespace, action, body: body, timeout: timeout, anonymous: anonymous);
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

  testWidgets('the computer tab shows the computer live and its power', (
    tester,
  ) async {
    final service = _Service()..state = 'asleep';
    await pumpTab(
      tester,
      SpaceComputerTab(
        dependencies: AppDependencies.withService(service),
        spaceId: FakeAsemanService.atlasId,
      ),
    );
    // Asleep: a dark screen, and the buttons to wake, replace and open it.
    expect(find.text('Asleep'), findsWidgets);
    expect(find.text('Wake up'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Forget logins'), findsNothing);
    expect(find.text('2 vCPU · 4.0 GB memory · 20.0 GB disk'), findsOneWidget);

    await tester.tap(find.text('Wake up'));
    await tester.pumpAndSettle();
    expect(service.operations, ['provision']);
    expect(find.text('Awake'), findsOneWidget);
    expect(find.text('Sleep'), findsOneWidget);
    expect(
      find.text('Sleeps after 2 min with nothing using it.'),
      findsOneWidget,
    );
    expect(find.text('Live view unavailable'), findsOneWidget);

    await tester.tap(find.text('Sleep'));
    await tester.pumpAndSettle();
    expect(service.operations, ['provision', 'sleep']);
    expect(find.text('Wake up'), findsOneWidget);

    // Asleep, there is no live view to keep the computer awake for.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the computer follows changes made elsewhere', (tester) async {
    final service = _Service()..state = 'asleep';
    await pumpTab(
      tester,
      SpaceComputerTab(
        dependencies: AppDependencies.withService(service),
        spaceId: FakeAsemanService.atlasId,
      ),
    );
    expect(find.text('Wake up'), findsOneWidget);
    // Someone else (or an agent) wakes it: the next watch says so.
    service.state = 'awake';
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Sleep'), findsOneWidget);
    expect(service.operations, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a phone, Open shows the computer in a bottom sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    final service = _Service()..state = 'asleep';
    await pumpTab(
      tester,
      SpaceComputerTab(
        dependencies: AppDependencies.withService(service),
        spaceId: FakeAsemanService.atlasId,
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Its files are kept while it sleeps.'), findsWidgets);
    // The sheet wakes it from its own dark screen, then closes.
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Wake up'),
      ),
    );
    await tester.pumpAndSettle();
    expect(service.operations, ['provision', 'keepalive']);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the memory tab edits the shared and each agent\'s notes', (
    tester,
  ) async {
    final service = _Service();
    await pumpTab(
      tester,
      SpaceMemoryTab(
        dependencies: AppDependencies.withService(service),
        spaceId: FakeAsemanService.atlasId,
        agents: await service
            .fetchSpaceBots(FakeAsemanService.atlasId)
            .then((b) => b.where((x) => x.isAgent).toList()),
      ),
    );
    expect(find.text('# Team notes'), findsOneWidget);
    expect(find.text('Saved'), findsWidgets);
    await tester.enterText(find.byType(TextField), '# Decided');
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.written['AGENTS.md'], '# Decided');

    expect(find.text('Saved'), findsWidgets);
    // Each agent's own notes are a chip away.
    await tester.ensureVisible(find.text('AssistBot').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('AssistBot').last);
    await tester.pumpAndSettle();
    expect(service.calls.last, 'read .decillion/agents/agent-1/AGENTS.md');
    expect(find.text('# Own notes'), findsOneWidget);
  });

  testWidgets('the previews tab shows each published page as a window', (
    tester,
  ) async {
    await pumpTab(
      tester,
      SpacePreviewsTab(
        dependencies: AppDependencies.withService(_Service()..state = 'asleep'),
        spaceId: FakeAsemanService.atlasId,
      ),
    );
    expect(find.text('Publish a port'), findsOneWidget);
    expect(find.text('Port 3000'), findsWidgets);
    expect(find.text('Asleep · wakes when opened'), findsOneWidget);
    expect(find.text('Desktop'), findsNothing);
    expect(find.text('Tool · Weather'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the space\'s left panel holds its facilities and app sign-ins', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'aseman.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
          '"token":"x","private_key":"","public_key":"",'
          '"home_space_id":"00000000000000010000000000000002"}',
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(_Service())),
    );
    await tester.pumpAndSettle();
    await openSpaceRoom(tester);

    await tester.tap(find.byTooltip('Apps'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Needs your sign-in'), findsOneWidget);
    expect(find.byTooltip('Connect your account'), findsOneWidget);
    expect(find.byTooltip('Reconnect your account'), findsOneWidget);

    await tester.tap(find.byTooltip('Computer'));
    await tester.pumpAndSettle();
    expect(find.text('Awake'), findsWidgets);
    await tester.tap(find.byTooltip('Memory'));
    await tester.pumpAndSettle();
    expect(find.text('# Team notes'), findsOneWidget);
    await tester.tap(find.byTooltip('Previews'));
    await tester.pumpAndSettle();
    expect(find.text('Port 3000'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
