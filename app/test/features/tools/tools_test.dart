import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/desk/domain/desk_models.dart';
import 'package:aseman/src/features/tools/data/tools_api.dart';
import 'package:aseman/src/features/tools/domain/tool_models.dart';
import 'package:aseman/src/features/tools/presentation/tool_create_form.dart';
import 'package:aseman/src/features/tools/presentation/tool_frontend_view.dart';
import 'package:aseman/src/features/tools/runtime/tool_frontend_host.dart';
import 'package:aseman/src/agui/agui.dart';
import 'package:aseman/src/shared/widgets/app_inputs.dart';

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
      expect(generative,
          {'mode': 'generative', 'skill': 'show it', 'cache': true});
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

    test('a frontend opened on a shown result asks for it, and keeps it',
        () async {
      final node = _Node();
      node.replies['tools.frontend_get'] =
          (_) => {'mode': 'generative', 'messages': <Object>[]};
      node.replies['tools.frontend_action'] =
          (_) => {'data': <String, dynamic>{}};
      const shown =
          ShownResult(microtool: 'weather_report', args: {'city': 'New York'});
      await node.api.frontend('b1', spaceId: 's1', shown: shown);
      await node.api
          .frontendAction('b1', 'metric', spaceId: 's1', shown: shown);
      for (final call in node.calls) {
        expect(call.$3['microtool'], 'weather_report');
        expect(call.$3['args'], {'city': 'New York'});
      }
      expect(ShownResult.fromProps({'tool': 'b1'}), isNull);
    });

    testWidgets(
        'a window designed for a request runs its own template, not the tool\'s',
        (tester) async {
      final node = _Node();
      const template = {'title': 'Tax notes', 'components': <Object>[]};
      node.replies['tools.frontend_get'] = (body) => body['template'] != null
          ? {
              'mode': 'generative',
              'request': true,
              'messages': [
                {
                  'version': 'v0.9',
                  'createSurface': {
                    'surfaceId': 'g',
                    'catalogId':
                        'https://aseman.app/agui/catalogs/aseman/v1'
                  }
                },
                {
                  'version': 'v0.9',
                  'updateComponents': {
                    'surfaceId': 'g',
                    'components': [
                      {
                        'id': 'root',
                        'component': 'Column',
                        'children': ['t', 'b']
                      },
                      {
                        'id': 't',
                        'component': 'Text',
                        'text': 'Generated for notes'
                      },
                      {
                        'id': 'b',
                        'component': 'Button',
                        'child': 'bl',
                        'action': {
                          'event': {'name': 'refresh'}
                        }
                      },
                      {'id': 'bl', 'component': 'Text', 'text': 'Refresh'},
                    ]
                  }
                },
              ],
            }
          : {'mode': ''};
      node.replies['tools.frontend_action'] =
          (_) => {'data': <String, dynamic>{}};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ToolFrontendView(
              api: node.api, botId: 'notes', spaceId: 's1', template: template),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Generated for notes'), findsOneWidget);
      final get = node.calls.singleWhere((c) => c.$2 == 'frontend_get');
      expect(get.$3['template'], template,
          reason: 'the node fills the window\'s own design');
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      final action = node.calls.lastWhere((c) => c.$2 == 'frontend_action');
      expect(action.$3['template'], template,
          reason: 'actions run against the window\'s design');
    });

    testWidgets(
        'a frontend generated for each request sends its own template back with its actions',
        (tester) async {
      final node = _Node();
      const generated = {'title': 'For you', 'components': <Object>[]};
      node.replies['tools.frontend_get'] = (_) => {
            'mode': 'generative',
            'cached': false,
            'template': generated,
            'messages': [
              {
                'version': 'v0.9',
                'createSurface': {
                  'surfaceId': 'g',
                  'catalogId':
                      'https://aseman.app/agui/catalogs/aseman/v1'
                }
              },
              {
                'version': 'v0.9',
                'updateComponents': {
                  'surfaceId': 'g',
                  'components': [
                    {
                      'id': 'root',
                      'component': 'Button',
                      'child': 'bl',
                      'action': {
                        'event': {'name': 'refresh'}
                      }
                    },
                    {'id': 'bl', 'component': 'Text', 'text': 'Refresh'},
                  ]
                }
              },
            ],
          };
      node.replies['tools.frontend_action'] =
          (_) => {'data': <String, dynamic>{}};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ToolFrontendView(
              api: node.api,
              botId: 'weather',
              spaceId: 's1',
              request: 'Compare Paris and Rome'),
        ),
      ));
      await tester.pumpAndSettle();
      final get = node.calls.singleWhere((c) => c.$2 == 'frontend_get');
      expect(get.$3['request'], 'Compare Paris and Rome');
      expect(get.$3.containsKey('template'), isFalse);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      final action = node.calls.lastWhere((c) => c.$2 == 'frontend_action');
      expect(action.$3['template'], generated);
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

  group('AG-UI surface view', () {
    List<Map<String, dynamic>> surface(Map<String, dynamic> data,
            {bool embed = false}) =>
        [
          {
            'version': 'v0.9',
            'createSurface': {
              'surfaceId': 's',
              'catalogId':
                  'https://aseman.app/agui/catalogs/aseman/v1'
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
          body: AgUiView(
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
          body: AgUiView(
            messages: surface({'greeting': 'Dashboard'}, embed: true),
            toolFrontend: (context, botId, height, props) {
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
          body: AgUiView(messages: [
            {
              'version': 'v0.9',
              'createSurface': {
                'surfaceId': 'w',
                'catalogId':
                    'https://aseman.app/agui/catalogs/aseman/v1'
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

    testWidgets('a ToolFrontend opens on the result an agent showed',
        (tester) async {
      ShownResult? got;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgUiView(
            messages: [
              {
                'version': 'v0.9',
                'createSurface': {
                  'surfaceId': 'w',
                  'catalogId':
                      'https://aseman.app/agui/catalogs/aseman/v1'
                }
              },
              {
                'version': 'v0.9',
                'updateComponents': {
                  'surfaceId': 'w',
                  'components': [
                    {
                      'id': 'root',
                      'component': 'ToolFrontend',
                      'tool': 'bot-wx',
                      'microtool': 'weather_report',
                      'args': {'city': 'New York'},
                      'height': 200,
                    }
                  ]
                }
              },
            ],
            toolFrontend: (context, botId, height, props) {
              got = ShownResult.fromProps(props);
              return SizedBox(
                  height: height, child: Text('frontend of $botId'));
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('frontend of bot-wx'), findsOneWidget);
      expect(got?.microtool, 'weather_report');
      expect(got?.args, {'city': 'New York'});
      expect(find.textContaining('Unknown'), findsNothing);
    });

    test('a composed desk window holds its widget\'s surface', () {
      final w = DeskWindow.fromJson({
        'id': 'w1',
        'tool': composedTool,
        'kind': composedKind,
        'title': 'Portfolio',
        'widget': {
          'title': 'Portfolio',
          'messages': surface({'greeting': 'x'})
        },
      });
      expect(w.isComposed, isTrue);
      expect(surfaceOf(w.widget), hasLength(3));
      expect(surfaceOf(const {}), isEmpty);
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

  testWidgets('a generative frontend offers the Cache frontend switch',
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
    expect(find.text('Cache frontend'), findsNothing,
        reason: 'only a generative frontend is cached');
    await tester.ensureVisible(find.text('Generative'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generative'));
    await tester.pumpAndSettle();
    final cache = find.widgetWithText(AppSwitchCard, 'Cache frontend');
    expect(cache, findsOneWidget);
    expect(tester.widget<AppSwitchCard>(cache).value, isTrue);
    await tester.ensureVisible(cache);
    await tester.pumpAndSettle();
    await tester.tap(cache);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Weather');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final frontend = draft!.toJson()['frontend'] as Map;
    expect(frontend['mode'], 'generative');
    expect(frontend['cache'], isFalse);
    expect(
        ToolInfo.fromJson({
          'frontend': {'mode': 'generative', 'cache': false}
        }).frontendCache,
        isFalse);
    expect(ToolInfo.fromJson({}).frontendCache, isTrue);
  });

  group('editing a tool', () {
    const managed = ToolInfo(
      botId: 'b1',
      name: 'Greeter',
      description: 'Says hello',
      mode: BackendMode.managed,
      runtime: ToolRuntime.quickjs,
      language: 'js',
      source: 'function tools() { return []; }',
      frontendMode: FrontendMode.generative,
      frontendSkill: 'Show a greeting.',
      editable: true,
    );

    test('tool_get carries what the tool was made from', () {
      final info = ToolInfo.fromJson({
        'bot_id': 'b1',
        'name': 'Greeter',
        'description': 'Says hello',
        'mode': 'external',
        'url': 'https://mcp.example.com/mcp',
        'auth': 'user',
        'frontend': {'mode': 'static', 'runtime': 'quickjs', 'language': 'js'},
        'frontend_source': 'app()',
        'editable': true,
      });
      expect(info.description, 'Says hello');
      expect(info.url, 'https://mcp.example.com/mcp');
      expect(info.auth, 'user');
      expect(info.frontendSource, 'app()');
      expect(info.frontendLanguage, 'js');
      expect(info.editable, isTrue);
    });

    test('edit sends only what changed', () async {
      final node = _Node()
        ..replies['tools.tool_update'] = (_) => <String, dynamic>{};
      await node.api.edit(
          'b1', const ToolEdit(name: 'Hello desk', url: 'https://x.dev/mcp'));
      expect(node.calls.single.$2, 'tool_update');
      expect(node.calls.single.$3,
          {'bot': 'b1', 'name': 'Hello desk', 'url': 'https://x.dev/mcp'});
      expect(const ToolEdit().isEmpty, isTrue);
    });

    Future<ToolEdit?> edit(WidgetTester tester, ToolInfo tool,
        Future<void> Function() change) async {
      ToolEdit? result;
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showEditToolForm(context, tool),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await change();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('the form opens filled and returns only the changes',
        (tester) async {
      final result = await edit(tester, managed, () async {
        expect(find.text('Edit app'), findsOneWidget);
        expect(find.text('Greeter'), findsOneWidget);
        expect(find.text('Show a greeting.'), findsOneWidget);
        // Where it runs is shown, not offered.
        expect(find.text('Where it runs'), findsNothing);
        await tester.enterText(
            find.widgetWithText(TextField, 'Description'), 'Greets people');
        await tester.enterText(
            find.widgetWithText(TextField, 'function tools() { return []; }'),
            'function tools() { return [1]; }');
      });
      expect(result, isNotNull);
      expect(result!.toJson(), {
        'description': 'Greets people',
        'source': 'function tools() { return [1]; }',
      });
    });

    testWidgets('turning the frontend cache off sends the frontend with it',
        (tester) async {
      final result = await edit(tester, managed, () async {
        final cache = find.widgetWithText(AppSwitchCard, 'Cache frontend');
        expect(cache, findsOneWidget);
        await tester.ensureVisible(cache);
        await tester.pumpAndSettle();
        await tester.tap(cache);
        await tester.pump();
      });
      expect(result!.toJson(), {
        'frontend': {
          'mode': 'generative',
          'skill': 'Show a greeting.',
          'cache': false
        },
      });
    });

    testWidgets('saving an unchanged tool changes nothing', (tester) async {
      final result = await edit(tester, managed, () async {});
      expect(result, isNull);
    });

    testWidgets('an external tool changes its server, not its program',
        (tester) async {
      const external = ToolInfo(
          botId: 'b2',
          name: 'Search',
          mode: BackendMode.external,
          url: 'https://old.dev/mcp',
          editable: true);
      final result = await edit(tester, external, () async {
        expect(find.text('Backend program'), findsNothing);
        await tester.enterText(find.widgetWithText(TextField, 'MCP server URL'),
            'https://new.dev/mcp');
        await tester.enterText(
            find.widgetWithText(TextField, 'New access token (optional)'),
            'secret');
      });
      expect(
          result!.toJson(), {'url': 'https://new.dev/mcp', 'token': 'secret'});
    });
  });
}
