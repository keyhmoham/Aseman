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
        'status': engine == 'opencode'
            ? 'OpenCode CLI runs every agent turn on its own free-model gateway.'
            : 'Deep Agents runs every agent turn.',
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
    expect(find.textContaining('platform LLM gateway'), findsWidgets);
    expect(find.text('Swarm'), findsOneWidget);
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
  });
}
