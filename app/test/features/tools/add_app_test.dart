import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/features/tools/connect/add_app.dart';
import 'package:aseman/src/features/tools/domain/mcp_directory.dart';

import '../../fake_aseman_service.dart';

/// A node with one catalog app that needs each person's account, and a
/// server that only answers once it is registered for per-person sign-in.
class _Service extends FakeAsemanService {
  final added = <String>[];
  final removed = <String>[];

  @override
  Future<List<({String id, String name, String auth, String avatar})>> mcpCatalog() async =>
      const [
        (id: 'bot-gh', name: 'GitHub', auth: 'user', avatar: ''),
        (id: 'bot-wx', name: 'Weather', auth: '', avatar: ''),
      ];

  @override
  Future<List<Bot>> fetchBots({int limit = 50, int offset = 0}) async => const [
        Bot(
            id: 'bot-mine',
            ownerId: 'me',
            accountId: 'acct-mine',
            name: 'My Chart',
            kind: 'tool',
            vmType: 'elpian',
            status: 'running'),
        // Listed in the catalog too: shown once.
        Bot(
            id: 'bot-gh',
            ownerId: 'me',
            accountId: 'acct-gh',
            name: 'GitHub',
            kind: 'tool',
            vmType: 'mcp',
            status: 'running'),
        Bot(
            id: 'agent-1',
            ownerId: 'me',
            accountId: 'acct-a',
            name: 'Helper',
            kind: 'agent',
            vmType: 'harness',
            status: 'running'),
      ];

  /// The directory is off here: these tests are about the node's own catalog
  /// and servers added by address (the directory has its own tests).
  @override
  Future<bool> glamaEnabled() async => false;

  @override
  Future<Set<String>> directoryKeysIn(String spaceId) async => <String>{};

  final byAddress = <Map<String, String>>[];

  /// A server added by address: this one wants a sign-in at its own provider.
  @override
  Future<McpInstalled> mcpInstall(
      {required String spaceId,
      String key = '',
      String url = '',
      String name = '',
      Map<String, String> headers = const {}}) async {
    byAddress.add({'space': spaceId, 'key': key, 'url': url, 'name': name});
    added.add('$spaceId/bot-new');
    return McpInstalled(
        botId: 'bot-new',
        name: name,
        status: 'needs_auth',
        method: 'oauth',
        auth: 'user');
  }

  @override
  Future<void> addBotToSpace(String spaceId, String botId,
      {String roomId = ''}) async {
    added.add('$spaceId/$botId');
  }

  @override
  Future<void> removeBotFromSpace(String spaceId, String botId,
      {String roomId = ''}) async {
    removed.add('$spaceId/$botId');
  }
}

/// Lets the dialogs open; the row being added keeps spinning behind the
/// sign-in dialog, so the screen never settles.
Future<void> _pumpDialogs(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Taps the n-th "Add" of the node's catalog (the dialog scrolls: the
/// directory above it pushes the list down).
Future<void> _tapAdd(WidgetTester tester, int n) async {
  final button = find.widgetWithText(FilledButton, 'Add').at(n);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

Future<Future<bool>> _open(WidgetTester tester, _Service service) async {
  late Future<bool> result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => FilledButton(
        onPressed: () =>
            result = showAddApp(context, service, spaceId: 'space-1'),
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
    expect(mcpAddFailure(Exception('that address answered, but not as an MCP server')),
        contains('not as an MCP server'));
  });

  testWidgets('adding a catalog app that needs an account asks to sign in',
      (tester) async {
    final service = _Service();
    final result = await _open(tester, service);
    expect(find.text('Add an app'), findsOneWidget);
    expect(find.text('Sign in with your own account'), findsOneWidget);

    await _tapAdd(tester, 0);
    await _pumpDialogs(tester);
    expect(service.added, ['space-1/bot-gh']);
    expect(find.text('Connect GitHub'), findsOneWidget);
    expect(find.text('Sign in with GitHub'), findsOneWidget);

    // Skipping the sign-in takes the app back out and keeps the dialog
    // open, so nothing half-added is left in the space.
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(service.removed, ['space-1/bot-gh']);
    expect(find.text('Add an app'), findsOneWidget);
    expect(find.textContaining('Sign-in was cancelled'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('the person\'s own apps can be added too, once each',
      (tester) async {
    final service = _Service();
    await _open(tester, service);
    expect(find.widgetWithText(ListTile, 'My Chart'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'GitHub'), findsOneWidget);
    expect(find.text('Helper'), findsNothing);
    await _tapAdd(tester, 2);
    await tester.pumpAndSettle();
    expect(service.added, ['space-1/bot-mine']);
  });

  testWidgets('a ready-to-use catalog app is added without a sign-in',
      (tester) async {
    final service = _Service();
    final result = await _open(tester, service);
    await _tapAdd(tester, 1);
    await tester.pumpAndSettle();
    expect(service.added, ['space-1/bot-wx']);
    expect(find.textContaining('Connect '), findsNothing);
    expect(await result, isTrue);
  });

  testWidgets(
      'a server added by address is installed in one call and asks to sign in when it wants to',
      (tester) async {
    final service = _Service();
    await _open(tester, service);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Linear');
    await tester.enterText(find.widgetWithText(TextField, 'Server address'),
        'https://mcp.linear.app/mcp');
    await tester.ensureVisible(find.text('Add server'));
    await tester.tap(find.text('Add server'));
    await _pumpDialogs(tester);

    // One call: the node asks the server what it wants, records it and adds it.
    expect(service.byAddress, [
      {'space': 'space-1', 'key': '', 'url': 'https://mcp.linear.app/mcp', 'name': 'Linear'}
    ]);
    expect(service.added, ['space-1/bot-new']);
    expect(find.text('Connect Linear'), findsOneWidget);
  });
}
