import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/features/admin/presentation/admin_screen.dart';

import '../../fake_aseman_service.dart';
import 'admin_fixtures.dart';

/// Remembers the engine the admin sets and serves it on the next read.
class _EngineService extends FakeAsemanService {
  _EngineService(this.data);
  final Map<String, dynamic> data;
  final sets = <Map<String, dynamic>>[];

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
  }) async {
    if (namespace == 'spaces' && action == 'agent_engine_set') {
      sets.add(Map<String, dynamic>.from(body));
      final engine = '${body['engine']}';
      data['spaces.agent_engine_get'] = {
        ...(data['spaces.agent_engine_get'] as Map),
        'engine': engine,
        'llm': engine == 'opencode' ? 'opencode-free' : 'platform',
        'status': switch (engine) {
          'opencode' =>
            'OpenCode CLI runs every agent turn on its own free-model gateway.',
          'deepseek' =>
            'DeepSeek Harness runs every agent turn with its own memory and swarm.',
          _ => 'Deep Agents runs every agent turn.',
        },
      };
      return data['spaces.agent_engine_get'];
    }
    return data['$namespace.$action'] ?? const <String, dynamic>{};
  }
}

void main() {
  testWidgets('admin switches the agentic engine and the page follows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _EngineService(adminFixtures());
    await tester.pumpWidget(
      MaterialApp(
        home: AdminScreen(dependencies: AppDependencies.withService(service)),
      ),
    );
    await tester.pump();
    final state = tester.state(find.byType(AdminScreen)) as dynamic;
    state.navigateToLabel('Agentic engine');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Deep Agents'), findsOneWidget);
    expect(find.textContaining('Headless OpenCode CLI'), findsOneWidget);
    expect(find.text('DeepSeek Harness'), findsOneWidget);
    expect(find.textContaining('platform LLM gateway'), findsWidgets);
    // Each CLI engine's mapping: Swarm is in both.
    expect(find.text('Swarm'), findsNWidgets(2));
    expect(find.text('When DeepSeek Harness runs the agents'), findsOneWidget);
    expect(find.text('When OpenCode runs the agents'), findsOneWidget);
    expect(find.textContaining('aseman-memory dsh plugin'), findsOneWidget);
    expect(
      find.textContaining('OpenCode CLI runs every agent turn'),
      findsNothing,
    );

    await tester.tap(find.textContaining('Headless OpenCode CLI'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(service.sets, [
      {'engine': 'opencode'},
    ]);
    expect(
      find.textContaining('OpenCode CLI runs every agent turn'),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('Headless DeepSeek Harness'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(service.sets.last, {'engine': 'deepseek'});
    expect(
      find.textContaining('own memory and swarm'),
      findsOneWidget,
    );
  });
}
