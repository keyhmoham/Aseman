import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/admin/presentation/admin_page_content.dart';

Map<String, dynamic> _provider(
        String id, String name, String key, List<String> models) =>
    {
      'id': id,
      'name': name,
      key: [
        for (final m in models) {'id': m, 'name': m}
      ],
    };

Future<List<(String, Map<String, dynamic>)>> _pump(
    WidgetTester tester, String page, Map<String, dynamic> results) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final calls = <(String, Map<String, dynamic>)>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AdminPageContent(
        page: page,
        loading: false,
        results: results,
        onRefresh: () async {},
        onAction: (_, __, ___) async {},
        onDirectAction: (ns, action, body) async {
          calls.add(('$ns.$action', Map<String, dynamic>.from(body)));
          return null;
        },
        onNavigate: (_) {},
      ),
    ),
  ));
  await tester.pump();
  return calls;
}

void main() {
  testWidgets('picking a decision provider saves it with its first model',
      (tester) async {
    final calls = await _pump(tester, 'Decision model', {
      'llm.llm_decision_get': {
        'enabled': false,
        'provider_id': '',
        'model_id': '',
        'providers': [
          _provider('p1', 'Fast AI', 'decision_models', ['fast-1', 'fast-2']),
          _provider('p2', 'Empty AI', 'decision_models', []),
        ],
      },
    });
    // Nothing to turn on yet.
    expect(
        find.textContaining('Pick a provider and model below'), findsOneWidget);

    // A provider without decision models is shown, not saved.
    await tester.tap(find.text('Empty AI'));
    await tester.pump();
    expect(calls, isEmpty);
    expect(find.textContaining('offers no model for this purpose'),
        findsOneWidget);

    await tester.tap(find.text('Fast AI'));
    await tester.pump();
    expect(calls.single.$1, 'llm.llm_decision_set');
    expect(calls.single.$2['provider_id'], 'p1');
    expect(calls.single.$2['model_id'], 'fast-1');
  });

  testWidgets('picking a memory provider saves it with its first model',
      (tester) async {
    final calls = await _pump(tester, 'Memory models', {
      'llm.llm_memory_get': {
        'chat_provider_id': '',
        'chat_model_id': '',
        'embedding_provider_id': '',
        'embedding_model_id': '',
        'providers': [
          {
            ..._provider('p1', 'Open AI', 'chat_models', ['chat-1']),
            'embedding_models': [
              {'id': 'embed-1', 'name': 'embed-1'}
            ],
          },
        ],
      },
    });
    // The chat slot comes first.
    await tester.tap(find.text('Open AI').first);
    await tester.pump();
    expect(calls.single.$1, 'llm.llm_memory_set');
    expect(calls.single.$2['chat_provider_id'], 'p1');
    expect(calls.single.$2['chat_model_id'], 'chat-1');
    expect(calls.single.$2['embedding_provider_id'], '');
  });
}
