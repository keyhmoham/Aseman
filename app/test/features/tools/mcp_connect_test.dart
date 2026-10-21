import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/features/tools/connect/mcp_connect_dialog.dart';
import 'package:aseman/src/features/tools/connect/mcp_sign_in.dart';
import 'package:aseman/src/features/tools/data/tools_api.dart';
import 'package:aseman/src/features/tools/presentation/tool_frontend_view.dart';

import '../../fake_aseman_service.dart';

/// Plays the node's side of an MCP sign-in.
class _Service extends FakeAsemanService {
  bool needsClient = true;
  final prepared = <Map<String, String>>[];
  final exchanged = <String>[];
  final connections = <Map<String, String>>[];

  @override
  Future<Map<String, dynamic>> mcpOAuthPrepare(
      {String url = '',
      String bot = '',
      required String redirectUri,
      String clientId = '',
      String clientSecret = ''}) async {
    prepared.add({'bot': bot, 'redirect': redirectUri, 'client': clientId});
    if (needsClient && clientId.isEmpty) {
      return {
        'needs_client': true,
        'redirect_uri': redirectUri,
        'error': 'Create an OAuth client.'
      };
    }
    return {
      'authorization_url':
          'https://login.example.com/authorize?client_id=$clientId&state=s1',
      'state': 's1',
    };
  }

  @override
  Future<Map<String, dynamic>> mcpOAuthExchange(
      String state, String code) async {
    exchanged.add('$state:$code');
    return {'access_token': 'at-1'};
  }

  @override
  Future<bool> setToolConnection(String botId, String spaceId,
      {String token = '', String grant = ''}) async {
    connections
        .add({'bot': botId, 'space': spaceId, 'token': token, 'grant': grant});
    return true;
  }
}

void main() {
  testWidgets('signing in exchanges the code and connects from the sign-in',
      (tester) async {
    final service = _Service()..needsClient = false;
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    String? opened;
    await McpSignIn(service).connect(context,
        botId: 'bot-gh',
        spaceId: 'space-1', open: (url, redirect, state) async {
      opened = url;
      return '$redirect?code=c1&state=$state';
    });
    expect(opened, startsWith('https://login.example.com/authorize'));
    expect(service.prepared.single['bot'], 'bot-gh');
    expect(service.prepared.single['redirect'], endsWith('/oauth.html'));
    expect(service.exchanged, ['s1:c1']);
    // The connection is made from the sign-in, so the node can renew it.
    expect(service.connections.single,
        {'bot': 'bot-gh', 'space': 'space-1', 'token': '', 'grant': 's1'});
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
    expect(service.exchanged, isEmpty);
    expect(service.connections, isEmpty);
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
    expect(service.prepared.last['client'], 'client-123');
    expect(service.connections.single['grant'], 's1');
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
    await tester.tap(find.text('Use an access token instead'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Access token'), ' secret-token ');
    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();
    expect(service.connections.single['token'], 'secret-token');
    expect(service.prepared, isEmpty);
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
