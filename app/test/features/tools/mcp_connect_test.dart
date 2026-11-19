import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/features/tools/connect/mcp_connect_dialog.dart';
import 'package:aseman/src/features/tools/connect/mcp_sign_in.dart';
import 'package:aseman/src/features/tools/data/tools_api.dart';
import 'package:aseman/src/features/tools/domain/mcp_directory.dart';
import 'package:aseman/src/features/tools/presentation/tool_frontend_view.dart';

import '../../fake_aseman_service.dart';

/// Plays the node's side of an MCP sign-in.
class _Service extends FakeAsemanService {
  bool needsClient = true;
  String noPage = ''; // a credential name: the server has no sign-in page
  final started = <Map<String, String>>[];
  final finished = <String>[];
  final tokens = <Map<String, String>>[];

  @override
  Future<ConnectStart> mcpConnectStart(
      {required String botId,
      required String spaceId,
      required String redirectUri,
      String clientId = '',
      String clientSecret = '',
      bool reconnect = false,
      bool freshClient = false}) async {
    started.add({
      'bot': botId,
      'space': spaceId,
      'redirect': redirectUri,
      'client': clientId,
      'fresh': '$freshClient',
    });
    if (noPage.isNotEmpty) {
      return ConnectStart('needs_token', credential: noPage);
    }
    if (needsClient && clientId.isEmpty) {
      return ConnectStart('needs_client',
          redirectUri: redirectUri, error: 'Create an OAuth client.');
    }
    return ConnectStart('authorize',
        authorizationUrl:
            'https://login.example.com/authorize?client_id=$clientId&state=s1',
        state: 's1');
  }

  @override
  Future<void> mcpConnectFinish(String state, String code) async {
    finished.add('$state:$code');
  }

  @override
  Future<void> mcpConnectToken(String botId, String spaceId, String token,
      {String username = '', String header = ''}) async {
    tokens.add({
      'bot': botId,
      'space': spaceId,
      'token': token,
      'username': username,
      'header': header
    });
  }
}

void main() {
  testWidgets('signing in brings the code back and the node keeps the connection',
      (tester) async {
    final service = _Service()..needsClient = false;
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    String? opened;
    final out = await McpSignIn(service).connect(context,
        botId: 'bot-gh',
        spaceId: 'space-1', open: (url, redirect, state) async {
      opened = url;
      return '$redirect?code=c1&state=$state';
    });
    expect(out.connected, isTrue);
    expect(opened, startsWith('https://login.example.com/authorize'));
    expect(service.started.single['bot'], 'bot-gh');
    expect(service.started.single['redirect'], endsWith('/oauth.html'));
    // The node trades the code and keeps the connection: no token returns here.
    expect(service.finished, ['s1:c1']);
  });

  testWidgets('a provider error or another attempt\'s state is refused',
      (tester) async {
    final service = _Service()..needsClient = false;
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    await expectLater(
        McpSignIn(service).connect(context,
            botId: 'b',
            spaceId: 's',
            open: (_, redirect, __) async =>
                '$redirect?error=access_denied&error_description=The+user+said+no'),
        throwsA(predicate((e) => mcpSignInMessage(e!) == 'The user said no')));
    await expectLater(
        McpSignIn(service).connect(context,
            botId: 'b',
            spaceId: 's',
            open: (_, redirect, __) async => '$redirect?code=c&state=other'),
        throwsA(predicate((e) => '$e'.contains('different attempt'))));
    expect(service.finished, isEmpty);
  });

  testWidgets(
      'a provider that wants a client shows its redirect, then signs in with it',
      (tester) async {
    final service = _Service();
    late Future<bool> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => FilledButton(
          onPressed: () => result = connectMcpTool(context, service,
              botId: 'bot-x',
              spaceId: 'space-1',
              name: 'Linear',
              open: (url, redirect, state) async =>
                  '$redirect?code=c2&state=$state'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Linear'), findsOneWidget);

    await tester.tap(find.text('Sign in with Linear'));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs an OAuth client you create'),
        findsOneWidget);
    expect(find.textContaining('/oauth.html'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Client id'), 'client-123');
    await tester.ensureVisible(find.text('Sign in with Linear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in with Linear'));
    await tester.pumpAndSettle();
    expect(service.started.last['client'], 'client-123');
    expect(service.finished, ['s1:c2']);
    expect(await result, isTrue);
  });

  testWidgets('a pasted token connects without signing in', (tester) async {
    final service = _Service();
    late Future<bool> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => FilledButton(
          onPressed: () => result = connectMcpTool(context, service,
              botId: 'bot-x', spaceId: 'space-1', name: 'Notion'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use a key or token instead'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Token'), ' secret-token ');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(service.tokens.single['token'], 'secret-token');
    expect(service.started, isEmpty);
    expect(await result, isTrue);
  });

  testWidgets(
      'a server with no sign-in page asks for its key, named as the app names it',
      (tester) async {
    final service = _Service()..noPage = 'api_key';
    late Future<bool> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => FilledButton(
          onPressed: () => result = connectMcpTool(context, service,
              botId: 'bot-k', spaceId: 'space-1', name: 'Keyed'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in with Keyed'));
    await tester.pumpAndSettle();
    // The node said there is no sign-in page: the key field takes its place.
    expect(find.widgetWithText(TextField, 'API key'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Header (optional)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'k-123');
    await tester.enterText(
        find.widgetWithText(TextField, 'Header (optional)'), 'X-Api-Key');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(service.tokens.single,
        {'bot': 'bot-k', 'space': 'space-1', 'token': 'k-123', 'username': '', 'header': 'X-Api-Key'});
    expect(await result, isTrue);
  });

  testWidgets(
      'a member who has not connected a per-person tool is asked to, where it opens',
      (tester) async {
    final service = _Member();
    var frontendAsked = false;
    final api = ToolsApi((ns, action, body, {timeout}) async {
      if (action == 'tool_frontend') frontendAsked = true;
      return <String, dynamic>{};
    }, service: service);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body:
                ToolFrontendView(api: api, botId: 'gh', spaceId: 'space-1'))));
    await tester.pumpAndSettle();
    expect(find.text('Connect your GitHub account'), findsOneWidget);
    expect(frontendAsked, isFalse);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Connect GitHub'), findsOneWidget);
    expect(find.text('Sign in with GitHub'), findsOneWidget);
  });
}

/// A member of a space with GitHub (each person connects) not yet connected.
class _Member extends _Service {
  @override
  Future<({String auth, bool connected, String name})> toolConnection(
          String botId, String spaceId) async =>
      (auth: 'user', connected: false, name: 'GitHub');

  @override
  Future<Map<String, ({String auth, bool connected, String name})>>
      toolConnections(String spaceId) async => {
            'gh': (auth: 'user', connected: false, name: 'GitHub'),
            'ln': (auth: 'user', connected: true, name: 'Linear'),
            'wx': (auth: '', connected: true, name: 'Weather'),
          };

  @override
  Future<List<Bot>> fetchSpaceBots(String spaceId) async => const [
        Bot(
            id: 'gh',
            ownerId: 'o',
            accountId: 'a-gh',
            name: 'GitHub',
            kind: 'tool',
            vmType: 'mcp',
            status: 'running'),
        Bot(
            id: 'wx',
            ownerId: 'o',
            accountId: 'a-wx',
            name: 'Weather',
            kind: 'tool',
            vmType: 'mcp',
            status: 'running'),
      ];
}
