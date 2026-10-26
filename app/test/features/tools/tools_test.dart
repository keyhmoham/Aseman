import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/tools/data/tools_api.dart';
import 'package:aseman/src/features/tools/domain/tool_models.dart';
import 'package:aseman/src/features/tools/presentation/tool_create_form.dart';
import 'package:aseman/src/features/tools/runtime/tool_frontend_host.dart';

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

    test('frontends: static with bytecode', () {
      final static = FrontendDraft(
          mode: FrontendMode.static,
          runtime: ToolRuntime.elpian,
          language: 'dart',
          bytecode: Uint8List.fromList([1, 2, 3])).toJson();
      expect(static['bytecode'], base64Encode([1, 2, 3]));
      expect(static['runtime'], 'elpian');
      expect(FrontendMode.parse('static'), FrontendMode.static);
      expect(FrontendMode.parse(''), FrontendMode.none);
      expect(FrontendMode.parse('unknown'), FrontendMode.none);
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
      node.replies['tools.frontend_get'] = (_) => {
            'mode': 'static',
            'runtime': 'quickjs',
            'source': 'askHost("render", "{}");',
          };
      const shown =
          ShownResult(microtool: 'weather_report', args: {'city': 'New York'});
      await node.api.frontend('b1', spaceId: 's1', shown: shown);
      expect(node.calls.single.$3['microtool'], 'weather_report');
      expect(node.calls.single.$3['args'], {'city': 'New York'});
      expect(ShownResult.fromProps({'tool': 'b1'}), isNull);
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

  group('editing a tool' , () {
    const managed = ToolInfo(
      botId: 'b1',
      name: 'Greeter',
      description: 'Says hello',
      mode: BackendMode.managed,
      runtime: ToolRuntime.quickjs,
      language: 'js',
      source: 'function tools() { return []; }',
      frontendMode: FrontendMode.static,
      frontendRuntime: ToolRuntime.quickjs,
      frontendLanguage: 'js',
      frontendSource: 'askHost("render", "{}");',
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
        expect(find.text('askHost("render", "{}");'), findsOneWidget);
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

    testWidgets('changing the static frontend program sends the frontend',
        (tester) async {
      final result = await edit(tester, managed, () async {
        await tester.enterText(
            find.widgetWithText(TextField, 'askHost("render", "{}");'),
            'askHost("render", JSON.stringify({type:"Text",props:{text:"hi"}}));');
      });
      expect(result!.toJson(), {
        'frontend': {
          'mode': 'static',
          'runtime': 'quickjs',
          'language': 'js',
          'source':
              'askHost("render", JSON.stringify({type:"Text",props:{text:"hi"}}));',
        },
      });
    });

    testWidgets('saving an unchanged tool changes nothing' , (tester) async {
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
