import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/data/models/llm_provider.dart';
import 'package:tradera/src/data/services/tradera_service.dart';
import 'package:tradera/src/features/admin/presentation/admin_widgets.dart';
import 'package:tradera/src/features/admin/presentation/llm_providers_tab.dart';
import 'package:tradera/src/features/agents/presentation/agent_create_form.dart';

const _openai = LlmProvider(
  id: 'p-openai',
  name: 'OpenAI',
  kind: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  isDefault: true,
  hasKey: true,
  keyPreview: 'sk-1••••abcd',
  imageModel: 'gpt-image-1',
  imagePrice: 20,
  models: [
    LlmModel(id: 'gpt-5.4', inputPrice: 1000, outputPrice: 4000),
    LlmModel(id: 'gpt-5.4-mini', inputPrice: 100, outputPrice: 400),
  ],
);

const _anthropic = LlmProvider(
  id: 'p-anthropic',
  name: 'Anthropic',
  kind: 'anthropic',
  models: [
    LlmModel(id: 'claude-sonnet-5-5', inputPrice: 3000, outputPrice: 15000)
  ],
);

/// Records the admin LLM calls instead of reaching a server.
class _FakeLlmService extends TraderaService {
  _FakeLlmService() : super(TraderaApiClient(baseUrl: 'http://localhost'));

  final saved = <Map<String, dynamic>>[];
  List<LlmProvider> providers = [_openai];

  @override
  Future<List<LlmProvider>> adminLlmProviders() async => providers;

  @override
  Future<List<LlmKind>> adminLlmKinds() async => const [
        LlmKind(
            kind: 'openai',
            name: 'OpenAI',
            baseUrl: 'https://api.openai.com/v1'),
        LlmKind(kind: 'grok', name: 'xAI Grok', baseUrl: 'https://api.x.ai/v1'),
      ];

  @override
  Future<LlmProvider> adminSetLlmProvider({
    String? id,
    required String name,
    required String kind,
    String baseUrl = '',
    String apiKey = '',
    bool enabled = true,
    bool isDefault = false,
    required List<LlmModel> models,
    String imageModel = '',
    double imagePrice = 0,
  }) async {
    saved.add({
      'name': name,
      'kind': kind,
      'base_url': baseUrl,
      'api_key': apiKey,
      'models': [for (final m in models) m.toJson()],
    });
    final p = LlmProvider(
        id: 'new', name: name, kind: kind, baseUrl: baseUrl, models: models);
    providers = [...providers, p];
    return p;
  }
}

void main() {
  test('LlmProvider parses admin and catalog payloads', () {
    final p = LlmProvider.fromJson({
      'id': 'x',
      'name': 'OpenAI',
      'kind': 'openai',
      'is_default': true,
      'key_preview': 'sk-1••••abcd',
      'has_key': true,
      'image_model': 'gpt-image-1',
      'image_price': 20,
      'models': [
        {'id': 'gpt-5.4', 'input_price': 1000, 'output_price': 4000.5},
      ],
    });
    expect(p.isDefault, isTrue);
    expect(p.hasImages, isTrue);
    expect(p.models.single.outputPrice, 4000.5);
    expect(formatCredits(4000.5), '0.4001');
    expect(formatCredits(1000), '0.1');
  });

  testWidgets('agent form picks the backbone from the admin LLM catalog',
      (tester) async {
    BotFormResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showCreateBotForm(context,
                loadLlmCatalog: () async => [_openai, _anthropic]);
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Default provider + its first model are preselected with their prices.
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('gpt-5.4'), findsOneWidget);
    expect(find.textContaining(r'$0.001 input'), findsOneWidget);

    // Switch to Anthropic: the model chips follow the provider.
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Anthropic'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Anthropic'));
    await tester.pumpAndSettle();
    expect(find.text('claude-sonnet-5-5'), findsOneWidget);
    expect(find.textContaining(r'$0.015 output'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Nova');
    await tester.enterText(
        find.widgetWithText(TextField, 'Instructions'), 'Trade carefully.');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Create'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.provider, 'p-anthropic');
    expect(result!.model, 'claude-sonnet-5-5');
  });

  testWidgets('agent form explains when no LLM provider is configured',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showCreateBotForm(context, loadLlmCatalog: () async => const []),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('No LLM provider is configured'), findsOneWidget);
  });

  testWidgets('admin LLM tab lists providers and adds a new one',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _FakeLlmService();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: LlmProvidersTab(service: service))));
    await tester.pumpAndSettle();

    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('DEFAULT'), findsOneWidget);
    // The provider card lists how many models it serves.
    expect(
        find.descendant(
            of: find.byType(AdminKeyValue), matching: find.text('2')),
        findsOneWidget);
    expect(find.textContaining('set under Models'), findsOneWidget);

    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();
    // Picking a kind fills its preset name and endpoint.
    await tester.tap(find.widgetWithText(ChoiceChip, 'xAI Grok'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'API key'), 'xai-secret');
    await tester.enterText(
        find.widgetWithText(TextField, 'Model id'), 'grok-5');
    await tester.enterText(
        find.widgetWithText(TextField, 'Input price'), '2000');
    await tester.enterText(
        find.widgetWithText(TextField, 'Output price'), '8000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(service.saved, hasLength(1));
    final s = service.saved.single;
    expect(s['kind'], 'grok');
    expect(s['name'], 'xAI Grok');
    expect(s['base_url'], 'https://api.x.ai/v1');
    expect(s['api_key'], 'xai-secret');
    expect(s['models'], [
      {'id': 'grok-5', 'input_price': 20000000.0, 'output_price': 80000000.0}
    ]);
    // The list reloads with the new provider.
    expect(find.text('xAI Grok'), findsOneWidget);
  });
}
