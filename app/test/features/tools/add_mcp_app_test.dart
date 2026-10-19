import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/features/tools/connect/add_mcp_app.dart';

import '../../fake_tradera_service.dart';

/// A node with one catalog app that needs each person's account, and a
/// server that only answers once it is registered for per-person sign-in.
class _Service extends FakeTraderaService {
  final registered = <Map<String, Object>>[];
  final added = <String>[];

  @override
  Future<List<({String id, String name, String auth})>> mcpCatalog() async =>
      const [
        (id: 'bot-gh', name: 'GitHub', auth: 'user'),
        (id: 'bot-wx', name: 'Weather', auth: ''),
      ];

  @override
  Future<String> mcpRegister(
      {required String name,
      required String url,
      String auth = '',
      String token = '',
      Map<String, dynamic> descriptor = const {}}) async {
    registered.add({'name': name, 'auth': auth, 'descriptor': descriptor});
    if (auth.isEmpty) throw Exception('MCP provider returned HTTP 401');
    return 'bot-new';
  }

  @override
  Future<void> addBotToSpace(String spaceId, String botId,
      {String roomId = ''}) async {
    added.add('$spaceId/$botId');
  }
}

/// Lets the dialogs open; the row being added keeps spinning behind the
/// sign-in dialog, so the screen never settles.
Future<void> _pumpDialogs(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<Future<bool>> _open(WidgetTester tester, _Service service) async {
  late Future<bool> result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => FilledButton(
        onPressed: () =>
            result = showAddMcpApp(context, service, spaceId: 'space-1'),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  test('sign-in failures are told apart from other failures', () {
    expect(mcpNeedsSignIn(Exception('MCP provider returned HTTP 401')), isTrue);
    expect(mcpNeedsSignIn(Exception('MCP provider returned HTTP 403')), isTrue);
    expect(
        mcpNeedsSignIn(Exception('MCP provider returned HTTP 404')), isFalse);
    expect(mcpAddFailure(Exception('MCP provider returned HTTP 404')),
        contains('/mcp'));
  });

  testWidgets('adding a catalog app that needs an account asks to sign in',
      (tester) async {
    final service = _Service();
    final result = await _open(tester, service);
    expect(find.text('Add an app'), findsOneWidget);
    expect(find.text('Sign in with your own account'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add').first);
    await _pumpDialogs(tester);
    expect(service.added, ['space-1/bot-gh']);
    expect(find.text('Connect GitHub'), findsOneWidget);
    expect(find.text('Sign in with GitHub'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('a ready-to-use catalog app is added without a sign-in',
      (tester) async {
    final service = _Service();
    final result = await _open(tester, service);
    await tester.tap(find.widgetWithText(FilledButton, 'Add').last);
    await tester.pumpAndSettle();
    expect(service.added, ['space-1/bot-wx']);
    expect(find.textContaining('Connect '), findsNothing);
    expect(await result, isTrue);
  });

  testWidgets(
      'a server that wants a sign-in is registered per person and asks to sign in',
      (tester) async {
    final service = _Service();
    await _open(tester, service);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Linear');
    await tester.enterText(find.widgetWithText(TextField, 'Server address'),
        'https://mcp.linear.app/mcp');
    await tester.ensureVisible(find.text('Add server'));
    await tester.tap(find.text('Add server'));
    await _pumpDialogs(tester);

    expect(service.registered.map((r) => r['auth']), ['', 'user']);
    expect((service.registered.last['descriptor'] as Map)['mcp_oauth'], 'auto');
    expect(service.added, ['space-1/bot-new']);
    expect(find.text('Connect Linear'), findsOneWidget);
  });
}
