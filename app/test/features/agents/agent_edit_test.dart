import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/data/models/llm_provider.dart';
import 'package:aseman/src/features/agents/presentation/agents_screen.dart';

import '../../fake_aseman_service.dart';

const _provider = LlmProvider(
  id: 'p-openai',
  name: 'OpenAI',
  kind: 'openai',
  isDefault: true,
  models: [
    LlmModel(id: 'gpt-5.4', inputPrice: 1000, outputPrice: 4000),
    LlmModel(id: 'gpt-5.4-mini', inputPrice: 100, outputPrice: 400),
  ],
);

/// One agent of the signed-in person, configured as bots.bot_detail reports
/// it; records what bots.bot_edit is asked to change.
class _Owner extends FakeAsemanService {
  final edits = <Map<String, Object?>>[];

  @override
  Future<List<Bot>> fetchBots({int limit = 100, int offset = 0}) async =>
      const [
        Bot(
            id: 'mine',
            ownerId: 'me',
            accountId: 'acct-mine',
            name: 'Nova Helper',
            vmType: 'deepagents',
            status: 'running'),
      ];

  @override
  Future<List<LlmProvider>> fetchLlmCatalog() async => const [_provider];

  @override
  Future<Map<String, dynamic>> fetchBotDetail(String botId) async => {
        'id': botId,
        'name': 'Nova Helper',
        'kind': 'agent',
        'vm_type': 'deepagents',
        'description': 'Helps with research',
        'resources': {'cpu': 2, 'memory_mb': 1024, 'disk_mb': 1024},
        'agent': {
          'description': 'Helps with research',
          'instructions': 'Scan the market.',
          'provider': 'p-openai',
          'model': 'gpt-5.4-mini',
          'max_turns': 10,
          'max_tokens': 4000,
          'skills': [
            {'name': 'Research', 'description': 'Agent capability: Research'}
          ],
        },
      };

  @override
  Future<void> editBot(String botId,
      {String? name,
      String? description,
      String? instructions,
      String? provider,
      String? model,
      int? maxTurns,
      int? maxTokens,
      List<Map<String, dynamic>>? skills,
      int? cpu,
      int? memoryMb,
      int? diskMb}) async {
    edits.add({
      'bot': botId,
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (instructions != null) 'instructions': instructions,
      if (provider != null) 'provider': provider,
      if (model != null) 'model': model,
      if (maxTurns != null) 'max_turns': maxTurns,
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (skills != null) 'skills': skills,
      if (cpu != null) 'cpu': cpu,
    });
  }
}

void main() {
  Future<_Owner> open(WidgetTester tester) async {
    final service = _Owner();
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body:
              AgentsScreen(dependencies: AppDependencies.withService(service))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('an agent opens in its form as it is configured', (tester) async {
    await open(tester);
    expect(find.text('Edit agent'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Nova Helper'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Scan the market.'), findsOneWidget);
    expect(find.text('gpt-5.4-mini'), findsWidgets);
    final research =
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Research'));
    expect(research.selected, isTrue);
  });

  testWidgets('saving sends only what was changed', (tester) async {
    final service = await open(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Scan the market.'), 'Scan FX.');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(service.edits, [
      {'bot': 'mine', 'instructions': 'Scan FX.'}
    ]);
    expect(find.text('Nova Helper saved'), findsOneWidget);
  });

  testWidgets('saving an unchanged agent changes nothing', (tester) async {
    final service = await open(tester);
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(service.edits, isEmpty);
  });
}
