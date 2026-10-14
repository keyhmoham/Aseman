import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/features/tools/data/tools_api.dart';
import 'package:tradera/src/features/tools/domain/tool_models.dart';
import 'package:tradera/src/features/tools/presentation/a2ui_view.dart';
import 'package:tradera/src/features/tools/presentation/composed_widget.dart';
import 'package:tradera/src/features/tools/presentation/tool_create_form.dart';
import 'package:tradera/src/features/tools/runtime/tool_frontend_host.dart';

/// Records node actions and answers them from [replies].
class _Node {
  final calls = <(String, String, Map<String, dynamic>)>[];
  final Map<String, dynamic Function(Map<String, dynamic>)> replies = {};

  ToolsApi get api => ToolsApi((ns, action, body, {timeout}) async {
        calls.add((ns, action, body));
        final reply = replies['$ns.$action'];
        return reply == null ? <String, dynamic>{} : reply(body);
      });
}

Map<String, dynamic> _mcp(Object value) => {
      'content': [
        {'type': 'text', 'text': jsonEncode(value)}
      ],
      if (value is Map) 'structuredContent': value,
      'isError': false,
    };

void main() {
  group('tool form wire format', () {
    test('an external backend sends its URL and credentials', () {
      final json = const ToolDraft(
        name: 'Docs',
        backend: BackendDraft(
            mode: BackendMode.external,
            url: 'https://mcp.example.com/mcp',
            auth: 'user'),
      ).toJson();
      expect(json['backend'], {
        'mode': 'external',
        'url': 'https://mcp.example.com/mcp',
        'auth': 'user'
      });
      expect(json['frontend'], {'mode': ''});
    });

    test('a managed Elpian backend sends its program and machine', () {
      final json = const ToolDraft(
        name: 'Greeter',
        backend: BackendDraft(
            mode: BackendMode.managed,
            runtime: ToolRuntime.elpian,
            language: 'dart',
            source: 'List tools() => [];',
            memoryMb: 256),
      ).toJson()['backend'] as Map<String, dynamic>;
      expect(json['runtime'], 'elpian');
      expect(json['language'], 'dart');
      expect(json['source'], 'List tools() => [];');
      expect((json['resources'] as Map)['memory'], 256);
    });

    test('an installed docker backend sends its image, not a program', () {
      final json = const ToolDraft(
        name: 'Img',
        backend: BackendDraft(
            mode: BackendMode.installed,
            runtime: ToolRuntime.docker,
            image: 'acme/tool:1',
            port: 9000),
      ).toJson()['backend'] as Map<String, dynamic>;
      expect(json, {
        'mode': 'installed',
        'runtime': 'docker',
        'image': 'acme/tool:1',
        'port': 9000,
        'path': '/mcp',
      });
    });

    test('frontends: static with bytecode, generative with a skill', () {
      final static = FrontendDraft(
          mode: FrontendMode.static,
          runtime: ToolRuntime.elpian,
          language: 'dart',
          bytecode: Uint8List.fromList([1, 2, 3])).toJson();
      expect(static['bytecode'], base64Encode([1, 2, 3]));
      expect(static['runtime'], 'elpian');
      final generative =
          const FrontendDraft(mode: FrontendMode.generative, skill: 'show it')
              .toJson();
      expect(generative, {'mode': 'generative', 'skill': 'show it'});
    });
  });

  group('microtool results', () {
    test('structured content, JSON text and plain text', () {
      expect(microtoolValue(_mcp({'t': 1})), {'t': 1});
      expect(
          microtoolValue({
            'content': [
              {'type': 'text', 'text': '[1,2]'}
            ]
          }),
          [1, 2]);
      expect(
          microtoolValue({
            'content': [
              {'type': 'text', 'text': 'hi'}
            ]
          }),
          'hi');
    });

    test('an error result throws', () {
      expect(
          () => microtoolValue({
                'content': [
                  {'type': 'text', 'text': 'boom'}
                ],
                'isError': true
              }),
          throwsA(isA<MicrotoolException>()));
    });
  });

  group('ToolsApi', () {
    test('invoke calls the microtool in the space and room, as data', () async {
      final node = _Node()
        ..replies['tools.invoke'] = (_) => {
              'result': _mcp({'text': 'hello'})
            };
      final value = await node.api.invoke('b1', 'greet',
          spaceId: 's1', roomId: 'r1', args: {'name': 'ada'});
      expect(value, {'text': 'hello'});
      expect(node.calls.single.$3, {
        'bot': 'b1',
        'space': 's1',
        'room': 'r1',
        'function': 'greet',
        'payload': {'name': 'ada'},
      });
    });

    test('frontend decodes a static Elpian frontend\'s bytecode', () async {
      final node = _Node()
        ..replies['tools.frontend_get'] = (_) => {
              'mode': 'static',
              'runtime': 'elpian',
              'bytecode': base64Encode([7, 8, 9]),
            };
      final payload = await node.api.frontend('b1', spaceId: 's1');
      expect(payload.mode, FrontendMode.static);
      expect(payload.runtime, ToolRuntime.elpian);
      expect(payload.bytecode, [7, 8, 9]);
    });
  });

  group('static frontend host', () {
    test('tool.call reaches the backend and answers in the typed envelope',
        () async {
      final node = _Node()
        ..replies['tools.invoke'] = (body) => {
              'result': _mcp({'echo': (body['payload'] as Map)['x']})
            };
      final host =
          ToolFrontendHost(node.api, botId: 'b1', spaceId: 's1', userId: 'u1');
      final raw = await host.handlers()['tool.call']!(
          'tool.call',
          jsonEncode([
            'echo',
            {'x': 5}
          ]));
      expect(jsonDecode(raw), {
        'type': 'object',
        'data': {
          'value': {'echo': 5}
        }
      });
      final ctx = await host.handlers()['tool.context']!('tool.context', '');
      expect((jsonDecode(ctx) as Map)['data']['value']['user'], 'u1');
    });

    test('a failing microtool is an error the program can read', () async {
      final node = _Node()
        ..replies['tools.invoke'] = (_) => {
              'result': {
                'content': [
                  {'type': 'text', 'text': 'nope'}
                ],
                'isError': true
              }
            };
      final host = ToolFrontendHost(node.api, botId: 'b1', spaceId: 's1');
      final raw = await host.handlers()['server.call']!(
          'server.call', jsonEncode(['f', <String, dynamic>{}]));
      expect((jsonDecode(raw) as Map)['data']['value']['error']['message'],
          'nope');
    });
  });

  group('A2UI view', () {
    List<Map<String, dynamic>> surface(Map<String, dynamic> data,
            {bool embed = false}) =>
        [
          {
            'version': 'v0.9',
            'createSurface': {
              'surfaceId': 's',
              'catalogId':
                  'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json'
            }
          },
          {
            'version': 'v0.9',
            'updateComponents': {
              'surfaceId': 's',
              'components': [
                {
                  'id': 'root',
                  'component': 'Column',
                  'children': ['title', 'go', if (embed) 'embedded']
                },
                {
                  'id': 'title',
                  'component': 'Text',
                  'text': {'path': '/greeting'}
                },
                {
                  'id': 'go',
                  'component': 'Button',
                  'child': 'go_label',
                  'action': {
                    'event': {
                      'name': 'greet',
                      'context': {'who': 'Ada'}
                    }
                  }
                },
                {'id': 'go_label', 'component': 'Text', 'text': 'Greet'},
                if (embed)
                  {
                    'id': 'embedded',
                    'component': 'ToolFrontend',
                    'tool': 'tool-2',
                    'height': 80
                  },
              ]
            }
          },
          {
            'version': 'v0.9',
            'updateDataModel': {'surfaceId': 's', 'path': '/', 'value': data}
          },
        ];

    testWidgets('shows bound data, runs actions and shows their data',
        (tester) async {
      String? action;
      Map<String, dynamic>? context;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: A2UIView(
            messages: surface({'greeting': 'Press the button'}),
            onAction: (a, data) async {
              action = a.name;
              context = a.context;
              return {'greeting': 'Hello, ${a.context['who']}!'};
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Press the button'), findsOneWidget);
      await tester.tap(find.text('Greet'));
      await tester.pumpAndSettle();
      expect(action, 'greet');
      expect(context, {'who': 'Ada'});
      expect(find.text('Hello, Ada!'), findsOneWidget);
    });

    testWidgets('embeds a tool\'s frontend where ToolFrontend stands',
        (tester) async {
      final embedded = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: A2UIView(
            messages: surface({'greeting': 'Dashboard'}, embed: true),
            toolFrontend: (context, botId, height) {
              embedded.add(botId);
              return SizedBox(
                  height: height, child: Text('frontend of $botId'));
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('frontend of tool-2'), findsOneWidget);
      expect(embedded, contains('tool-2'));
      expect(find.textContaining('Unknown component'), findsNothing);
    });

    testWidgets('fills {{…}} and \${…} placeholders agents write as plain text',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: A2UIView(messages: [
            {
              'version': 'v0.9',
              'createSurface': {
                'surfaceId': 'w',
                'catalogId':
                    'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json'
              }
            },
            {
              'version': 'v0.9',
              'updateComponents': {
                'surfaceId': 'w',
                'components': [
                  {
                    'id': 'root',
                    'component': 'Column',
                    'children': ['emoji', 'temp', 'days']
                  },
                  {
                    'id': 'emoji',
                    'component': 'Text',
                    'text': '{{/forecast/current/emoji}}'
                  },
                  {
                    'id': 'temp',
                    'component': 'Text',
                    'text': 'Feels like {{ /forecast/current/feels_like }}°',
                  },
                  {
                    'id': 'days',
                    'component': 'List',
                    'children': {'componentId': 'day', 'path': '/forecast/days'}
                  },
                  {
                    'id': 'day',
                    'component': 'Text',
                    'text': r'${label}: ${high_text}'
                  },
                ]
              }
            },
            {
              'version': 'v0.9',
              'updateDataModel': {
                'surfaceId': 'w',
                'path': '/',
                'value': {
                  'forecast': {
                    'current': {'emoji': '☀️', 'feels_like': 21},
                    'days': [
                      {'label': 'Mon', 'high_text': '24°'},
                      {'label': 'Tue', 'high_text': '19°'},
                    ],
                  }
                },
              }
            },
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('{{'), findsNothing);
      expect(find.textContaining(r'${'), findsNothing);
      expect(find.text('☀️'), findsOneWidget);
      expect(find.text('Feels like 21°'), findsOneWidget);
      expect(find.text('Mon: 24°'), findsOneWidget);
      expect(find.text('Tue: 19°'), findsOneWidget);
    });

    test('a composed widget message is read from its body', () {
      final body = jsonEncode({
        'title': 'Portfolio',
        'messages': surface({'greeting': 'x'})
      });
      final parsed = ComposedWidgetCard.parse(body)!;
      expect(parsed.title, 'Portfolio');
      expect(parsed.messages, hasLength(3));
      expect(ComposedWidgetCard.parse('plain text'), isNull);
    });
  });

  testWidgets(
      'the tool form returns a managed QuickJS tool with a static frontend by default',
      (tester) async {
    ToolDraft? draft;
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => draft = await showCreateToolForm(context),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Backend'.toUpperCase()), findsOneWidget);
    expect(find.text('Frontend'.toUpperCase()), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Greeter');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(draft, isNotNull);
    final json = draft!.toJson();
    expect(json['name'], 'Greeter');
    expect((json['backend'] as Map)['mode'], 'managed');
    expect((json['backend'] as Map)['runtime'], 'quickjs');
    expect((json['backend'] as Map)['source'], contains('function tools()'));
    expect((json['frontend'] as Map)['mode'], 'static');
  });
}
