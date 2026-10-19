import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/data/models/bot.dart';
import 'package:tradera/src/data/models/space.dart';
import 'package:tradera/src/features/home/presentation/project_control_content.dart';
import 'package:tradera/src/features/home/presentation/space_settings_panel.dart';
import 'package:tradera/src/features/tools/connect/mcp_connect_dialog.dart';
import 'package:tradera/src/features/tools/connect/mcp_sign_in.dart';
import 'package:tradera/src/features/tools/data/tools_api.dart';
import 'package:tradera/src/features/tools/presentation/tool_frontend_view.dart';

import '../../fake_tradera_service.dart';

/// Plays the node's side of an MCP sign-in.
class _Service extends FakeTraderaService {
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

  testWidgets('the project plugins say which tools need your account',
      (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProjectControlContent(
          area: 'Plugins',
          spaceId: 'space-1',
          results: const {
            'spaces.tools_list': {
              'tools': [
                {'id': 'gh', 'name': 'GitHub'},
                {'id': 'ln', 'name': 'Linear'},
                {'id': 'wx', 'name': 'Weather'},
              ]
            },
            'tools.commands_list': {
              'tools': [
                {'bot_id': 'gh', 'auth': 'user', 'connected': false},
                {'bot_id': 'ln', 'auth': 'user', 'connected': true},
                {'bot_id': 'wx', 'auth': '', 'connected': true},
              ]
            },
          },
          onAction: (_, __, ___) async {},
          onConnect: (bot, name, reconnect) async =>
              asked.add('$bot:$name:$reconnect'),
        ),
      ),
    ));
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    await tester.tap(find.text('Connect'));
    await tester.tap(find.text('Reconnect'));
    expect(asked, ['gh:GitHub:false', 'ln:Linear:true']);
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

  testWidgets('every member sees their own app connections in the space',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Member();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceSettingsPanel(
                dependencies: AppDependencies.withService(service),
                space: const Workspace(
                    id: 'space-1',
                    ownerId: 'someone-else',
                    name: 'Desk',
                    role: 'member')))));
    await tester.pumpAndSettle();
    expect(find.text('Your app connections'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    // A tool of another space, and one everyone shares, are not listed.
    expect(find.text('Linear'), findsNothing);
    expect(find.text('Weather'), findsNothing);
    await tester.ensureVisible(find.text('Connect'));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
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
