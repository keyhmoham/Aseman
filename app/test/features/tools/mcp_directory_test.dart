import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/agui/governance_cards.dart';
import 'package:aseman/src/agui/surface.dart';
import 'package:aseman/src/agui/surface_view.dart';
import 'package:aseman/src/features/tools/connect/mcp_directory_view.dart';
import 'package:aseman/src/features/tools/connect/mcp_login_card.dart';
import 'package:aseman/src/features/tools/connect/mcp_sign_in.dart';
import 'package:aseman/src/features/tools/domain/mcp_directory.dart';

import '../../fake_aseman_service.dart';

Map<String, dynamic> _conn(String key,
        {String auth = 'oauth2', int tools = 3, Map<String, dynamic>? extra}) =>
    {
      'key': key,
      'name': key.split('/').last,
      'description': 'Does $key things',
      'glama_url': 'https://glama.ai/mcp/connectors/$key',
      'auth': auth,
      'mcp_url': 'https://x/mcp',
      'tool_count': tools,
      ...?extra,
    };

void main() {
  group('the directory logic', () {
    test('what a server asks of the person is said in a word', () {
      expect(authLabel('oauth2'), 'Sign in');
      expect(authLabel('api_key'), 'API key');
      expect(authLabel('basic'), 'Login');
      expect(authLabel('none'), 'Open');
      expect(authLabel('weird'), '');
    });

    test('a row\'s small print counts tools and warns of a silent server', () {
      expect(GlamaConnector.fromJson(_conn('a/b', auth: 'none', tools: 1)).summary,
          '1 tool · Open');
      expect(
          GlamaConnector.fromJson(
                  _conn('a/b', tools: 12, extra: {'healthy': false}))
              .summary,
          '12 tools · Sign in · Not answering lately');
      expect(GlamaConnector.fromJson(_conn('a/b', tools: 0)).summary, 'Sign in');
    });

    test('quality shows only when the directory scored it', () {
      expect(GlamaConnector.fromJson(_conn('a/b', extra: {'quality': 4.46})).qualityLabel, '4.5 / 5');
      expect(GlamaConnector.fromJson(_conn('a/b', extra: {'quality': 0})).qualityLabel, '');
      expect(GlamaConnector.fromJson(_conn('a/b')).qualityLabel, '');
    });

    test('sign-in filters come from the directory\'s own list', () {
      final filters = authFilters(const [
        GlamaFilter(key: 'auth:oauth2', name: 'OAuth 2.0'),
        GlamaFilter(key: 'capability:tools', name: 'Tools'),
        GlamaFilter(key: 'auth:none', name: 'No auth'),
        GlamaFilter(key: 'auth:new_kind', name: 'New kind'),
      ]);
      expect(filters.map((f) => f.label),
          ['All', 'Sign in', 'No sign-in', 'New kind']);
      expect(filters[1].attributes, ['auth:oauth2']);
      expect(authFilters(const []).single.id, 'all');
    });

    test('pages are joined and a repeated server shows once', () {
      final merged = mergePages([
        GlamaPage.fromJson({
          'connectors': [_conn('a/one'), _conn('a/two')],
          'has_more': true,
          'next': 'x'
        }),
        GlamaPage.fromJson({
          'connectors': [_conn('a/two'), _conn('b/three')]
        }),
      ]);
      expect(merged.map((c) => c.key), ['a/one', 'a/two', 'b/three']);
      // A page that says there is more but names no cursor has no more.
      expect(GlamaPage.fromJson({'connectors': [], 'has_more': true}).hasMore, isFalse);
    });

    test('what is left to do after adding a server', () {
      McpInstalled got(Map<String, dynamic> j) => McpInstalled.fromJson({'bot_id': 'b', 'name': 'N', ...j});
      expect(got({'status': 'ready'}).next.kind, 'done');
      expect(got({'status': 'connected'}).next.kind, 'done');
      expect(got({'status': 'needs_auth', 'method': 'oauth'}).next.kind, 'oauth');
      final key = got({'status': 'needs_auth', 'method': 'token', 'credential': 'api_key'}).next;
      expect([key.kind, key.credential], ['token', 'api_key']);
    });

    test('the key\'s field is named for what the app calls its key', () {
      expect(credentialFields('basic').username, isTrue);
      expect(credentialFields('api_key').header, isTrue);
      expect(credentialFields('api_key').label, 'API key');
      expect(credentialFields('').label, 'Token');
    });

    test('a long list of tools is cut and says how many are left', () {
      final tools = [for (var i = 0; i < 11; i++) GlamaTool(name: 't$i')];
      final p = toolPreview(tools);
      expect([p.shown.length, p.more], [8, 3]);
      expect(toolPreview(const []).more, 0);
    });

    test('search words are tidied before they are sent', () {
      expect(searchTerm('  hacker   news '), 'hacker news');
      expect(searchTerm('   '), '');
    });
  });

  group('the login card', () {
    test('the card says whether the person is signed in, as the node says', () {
      expect(loginCardState(loading: true, failed: false), LoginCardState.loading);
      expect(loginCardState(loading: false, failed: false, auth: 'user', connected: false), LoginCardState.needs);
      expect(loginCardState(loading: false, failed: false, auth: 'user', connected: true), LoginCardState.connected);
      expect(loginCardState(loading: false, failed: false, auth: ''), LoginCardState.open);
      expect(loginCardState(loading: false, failed: true), LoginCardState.unknown);
    });

    test('a card with no app or no place to sign in from is not drawn', () {
      expect(LoginCard.fromProps({'name': 'N', 'space': 's'}), isNull);
      expect(LoginCard.fromProps({'bot': 'b', 'name': 'N'}), isNull);
      final ok = LoginCard.fromProps({
        'bot': 'b',
        'name': ' Notion ',
        'space': 's',
        'reason': 'to read pages',
        'glama_url': 'https://glama.ai/mcp/connectors/a/b',
        'credential': 'api_key'
      })!;
      expect([ok.name, ok.reason, ok.glamaUrl, ok.credential], ['Notion', 'to read pages', 'https://glama.ai/mcp/connectors/a/b', 'api_key']);
    });

    test('a notes card is read with the same rules; only Glama is linked', () {
      final card = LoginCard.fromProps({'id': 'b', 'title': 'Sentry', 'space': 's', 'subtitle': 'for errors', 'link': 'https://evil.example.com/x'})!;
      expect([card.bot, card.name, card.reason, card.glamaUrl], ['b', 'Sentry', 'for errors', '']);
      final cards = loginCardsOf([
        {'type': 'connect', 'id': 'b', 'title': 'Sentry', 'space': 's'},
        {'type': 'room', 'id': 'r', 'title': 'Room'},
        {'type': 'connect', 'title': 'No app'},
      ]);
      expect(cards.map((c) => c.name), ['Sentry']);
      expect(loginCardsOf(null), isEmpty);
    });
  });

  group('the directory in the add-app dialog', () {
    testWidgets('searching, adding a sign-in app and signing in is one tap',
        (tester) async {
      final service = _Directory();
      final sign = _Sign(service);
      var installed = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: McpDirectoryView(
              service: service,
              spaceId: 'space-1',
              installed: const {'acme/old'},
              onInstalled: () => installed++,
              sign: sign,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // The licence: a credit on the screen and a link to each listing.
      expect(find.text('MCP data from Glama'), findsOneWidget);
      expect(find.text('View on Glama'), findsNWidgets(2));
      expect(find.text('Sign in'), findsWidgets); // the filter and the row's small print
      expect(find.text('Added'), findsOneWidget); // acme/old is already here
      expect(find.text('Promoted'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(service.installed, [{'space': 'space-1', 'key': 'acme/thing'}]);
      // The sign-in is the node's: it begins for the app just added.
      expect(sign.connected, ['space-1/bot-1']);
      expect(installed, greaterThan(0));
    });

    testWidgets('a node without the directory says so', (tester) async {
      final service = _Directory()..enabled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: McpDirectoryView(service: service, spaceId: 's', installed: const {}, onInstalled: () {})),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('not set up on this node'), findsOneWidget);
      expect(find.text('MCP data from Glama'), findsNothing);
    });

    testWidgets('a server that is down is told, and nothing is signed in',
        (tester) async {
      final service = _Directory()..installError = 'that server could not be reached from here';
      final sign = _Sign(service);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: McpDirectoryView(service: service, spaceId: 's', installed: const {}, onInstalled: () {}, sign: sign))),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('could not be reached'), findsOneWidget);
      expect(sign.connected, isEmpty);
    });
  });

  group('the login card in the chat', () {
    testWidgets('an app that wants a sign-in shows a Sign in button', (tester) async {
      final service = _Directory();
      final sign = _Sign(service);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: McpLoginCardView(
            service: service,
            sign: sign,
            card: const LoginCard(bot: 'bot-1', space: 'space-1', name: 'Notion', reason: 'to read your pages', glamaUrl: 'https://glama.ai/mcp/connectors/a/b'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Sign in to Notion'), findsOneWidget);
      expect(find.text('to read your pages'), findsOneWidget);
      expect(find.text('View on Glama'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(sign.connected, ['space-1/bot-1']);
      // Asked again after signing in, the node says connected.
      expect(find.text('Signed in to Notion'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('a person already signed in sees it, wherever the card is read',
        (tester) async {
      final service = _Directory()..signedIn = true;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: McpLoginCardView(
            service: service,
            card: const LoginCard(bot: 'bot-1', space: 'space-1', name: 'Notion'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Signed in to Notion'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsNothing);
    });

    testWidgets('a Connect surface in a room draws the card; elsewhere it points to the app',
        (tester) async {
      final surface = AgUiSurface.fromJson({
        'version': 'decillion.surface/v1',
        'title': 'Sign in',
        'root': {
          'c': 'Connect',
          'p': {'bot': 'bot-1', 'name': 'Notion', 'space': 'space-1', 'method': 'oauth'}
        }
      });
      final service = _Directory();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgUiActions(
            invoke: (a, b, c) async => null,
            connectBuilder: (context, props) => McpLoginCardView(
                service: service,
                card: LoginCard.fromProps(props)!,
                sign: _Sign(service)),
            child: AgUiSurfaceView(surface: surface),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AgUiSurfaceView(surface: surface))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Open this conversation in the app to sign in'), findsOneWidget);
    });
  });
}

/// A node with a directory of two servers (one promoted, one already added).
class _Directory extends FakeAsemanService {
  bool enabled = true;
  bool signedIn = false;
  String installError = '';
  final installed = <Map<String, String>>[];

  @override
  Future<bool> glamaEnabled() async => enabled;

  @override
  Future<List<GlamaFilter>> glamaAttributes() async => const [
        GlamaFilter(key: 'auth:oauth2', name: 'OAuth 2.0'),
        GlamaFilter(key: 'auth:none', name: 'No auth'),
      ];

  @override
  Future<GlamaPage> glamaSearch(
          {String query = '',
          List<String> attributes = const [],
          String after = '',
          int first = 20}) async =>
      GlamaPage.fromJson({
        'connectors': [
          _conn('acme/thing', extra: {'boosted': true}),
          _conn('acme/old', auth: 'none'),
        ],
      });

  @override
  Future<GlamaConnector> glamaGet(String key) async => GlamaConnector.fromJson(_conn(key, extra: {
        'tools': [
          {'name': 'find', 'description': 'Finds things'}
        ]
      }));

  @override
  Future<McpInstalled> mcpInstall(
      {required String spaceId,
      String key = '',
      String url = '',
      String name = '',
      Map<String, String> headers = const {}}) async {
    if (installError.isNotEmpty) throw Exception(installError);
    installed.add({'space': spaceId, 'key': key});
    return const McpInstalled(
        botId: 'bot-1', name: 'thing', status: 'needs_auth', method: 'oauth', auth: 'user');
  }

  @override
  Future<Set<String>> directoryKeysIn(String spaceId) async => <String>{};

  @override
  Future<({String auth, bool connected, String name})> toolConnection(
          String botId, String spaceId) async =>
      (auth: 'user', connected: signedIn, name: 'Notion');
}

/// Plays the sign-in: the provider's page, then the node keeping it.
class _Sign extends McpSignIn {
  _Sign(this.directory) : super(directory);
  final _Directory directory;
  final connected = <String>[];

  @override
  Future<McpConnectOutcome> connect(BuildContext context,
      {required String botId,
      required String spaceId,
      String clientId = '',
      String clientSecret = '',
      bool reconnect = false,
      OAuthOpener? open,
      dynamic window}) async {
    connected.add('$spaceId/$botId');
    directory.signedIn = true;
    return const McpConnectOutcome('connected');
  }
}
