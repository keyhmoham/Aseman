// AG-UI in Elpian mini apps: the transport's chunk-split NDJSON
// decoding, conversations, the registry, the AgUiSurface widget and the agent
// host APIs. (The catalog and rendering are tested in test/agui.)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/agui/agui.dart' show asemanCatalogId;
import 'package:aseman/src/elpian/elpian.dart';
import 'package:aseman/src/elpian/widgets/svg_path.dart';

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File('test/agui/$path').readAsStringSync())
        as Map<String, dynamic>;

/// A scripted [AgentFetchStream]: records requests, replays chunks.
class FakeAgent {
  final List<({String url, Map<String, dynamic> body})> requests = [];
  List<String> chunks = const [];
  String? error;

  void Function() call(
    AgentEndpoint endpoint,
    String body, {
    required void Function(String chunk) onChunk,
    required void Function() onDone,
    required void Function(String message) onError,
  }) {
    requests.add(
        (url: endpoint.url, body: jsonDecode(body) as Map<String, dynamic>));
    final chunks = this.chunks;
    final error = this.error;
    var cancelled = false;
    () async {
      for (final c in chunks) {
        await Future<void>.delayed(Duration.zero);
        if (cancelled) return;
        onChunk(c);
      }
      await Future<void>.delayed(Duration.zero);
      if (cancelled) return;
      if (error != null) {
        onError(error);
      } else {
        onDone();
      }
    }();
    return () => cancelled = true;
  }
}

Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  test('svgPath icons parse', () {
    final path = parseSvgPath(
        'M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z');
    final b = path.getBounds();
    expect(b.left, closeTo(2, 0.01));
    expect(b.right, closeTo(22, 0.01));
    final arc = parseSvgPath('M2 12a10 10 0 1020 0 10 10 0 10-20 0z');
    expect(arc.getBounds().width, closeTo(20, 0.1));
  });

  test('NDJSON decoding survives arbitrary chunk splits', () {
    final lines = [
      {'type': 'conversation', 'conversationId': 'c1'},
      {
        'version': 'v0.9.1',
        'createSurface': {'surfaceId': 's', 'catalogId': asemanCatalogId}
      },
      {'type': 'text', 'text': 'héllo — ünïcode ✓'},
      {'type': 'done', 'stopReason': 'end_turn'},
    ];
    final text = '${lines.map(jsonEncode).join('\n')}\n';
    for (final size in [1, 2, 3, 7, 13, text.length]) {
      final d = NdjsonDecoder();
      final out = <Object?>[];
      for (var i = 0; i < text.length; i += size) {
        out.addAll(d.push(text.substring(i, (i + size).clamp(0, text.length))));
      }
      out.addAll(d.end());
      expect(out, lines, reason: 'chunk size $size');
    }
    final d = NdjsonDecoder();
    expect(d.push('{"a":1}\r\n{"b"'), [
      {'a': 1}
    ]);
    expect(d.push(':2}'), isEmpty);
    expect(d.end(), [
      {'b': 2}
    ]);
  });

  test('a conversation streams a turn from a fake agent', () async {
    final agent = FakeAgent()
      ..chunks = [
        '{"type":"conversation","conversationId":"conv-1"}\n{"version":"v0.9.1","createSurface":{"surfaceId":"s","catalogId":"$asemanCatalogId","sendDataModel":true}}\n',
        '{"version":"v0.9.1","updateComponents":{"surfaceId":"s","components":[{"id":"root","component":"Text","text":{"path":"/greeting"}}]}}\n{"version":"v0.9',
        '.1","updateDataModel":{"surfaceId":"s","path":"/greeting","value":"Hello"}}\n{"type":"text","text":"Here you go"}\n{"type":"done","stopReason":"end_turn"}\n',
      ];
    final conv = AgUiConversation(
        endpoint: const AgentEndpoint(
            baseUrl: 'http://agent.test/', appId: 'shop', agent: 'assistant'),
        fetch: agent.call);
    final events = <String>[];
    conv.on((e) => events.add(e.type));
    final turn = conv.send('hi');
    expect(await turn.conversationId, 'conv-1');
    final done = await turn.done;
    expect(done.conversationId, 'conv-1');
    expect(done.stopReason, 'end_turn');
    expect(agent.requests.first.url,
        'http://agent.test/apps/shop/agent/assistant');
    expect(agent.requests.first.body['message'], 'hi');
    expect(
        agent.requests.first.body['capabilities']['supportedCatalogIds'],
        contains(asemanCatalogId));
    expect((conv.dataModel('s') as Map)['greeting'], 'Hello');
    expect(conv.transcript.map((t) => t.toJson()), [
      {'role': 'user', 'text': 'hi'},
      {'role': 'agent', 'text': 'Here you go'},
    ]);
    expect(events, containsAll(['done', 'text', 'conversation']));
    agent.chunks = ['{"type":"done","stopReason":"end_turn"}'];
    await conv.sendAction({
      'name': 'x',
      'surfaceId': 's',
      'sourceComponentId': 'root',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'context': {}
    }).done;
    final second = agent.requests[1].body;
    expect(second['conversationId'], 'conv-1');
    expect(second['action']['name'], 'x');
    expect(second['dataModel'], {
      'version': 'agui-surface/1',
      'surfaces': {
        's': {'greeting': 'Hello'}
      }
    });
    agent
      ..chunks = []
      ..error = 'HTTP status 500';
    expect((await conv.send('again').done).stopReason, 'error');
  });

  test('agent endpoints resolve from the registry defaults', () {
    final registry = AgUiRegistry();
    expect(registry.endpoint('assistant'), isNull, reason: 'no defaults');
    registry.defaults =
        const AgUiDefaults(baseUrl: 'http://localhost:8080/', appId: 'shop');
    expect(registry.endpoint('assistant')!.url,
        'http://localhost:8080/apps/shop/agent/assistant');
    expect(registry.endpoint('')?.url, isNull, reason: 'no agent');
    expect(
        registry
            .endpoint('a b', appId: 'other/app', baseUrl: 'https://x.dev')!
            .url,
        'https://x.dev/apps/other%2Fapp/agent/a%20b');
    // A widget without `app` / `baseUrl` reaches the current app's agent.
    final conv = agUiConversationFor(registry, {'agent': 'assistant'}, 'w');
    expect(
        conv.endpoint!.url, 'http://localhost:8080/apps/shop/agent/assistant');
    // Static messages never reach an agent.
    final stat = agUiConversationFor(
        registry, {'agent': 'assistant', 'messages': []}, 'w2');
    expect(stat.endpoint, isNull);
  });

  testWidgets('ElpianVmWidget points the app registry at its agents',
      (tester) async {
    final engine = ElpianEngine(services: ElpianServices(appId: 'vm'));
    await tester.pumpWidget(MaterialApp(
      home: ElpianVmWidget.fromAst(
        machineId: 'a2ui-defaults',
        astJson: '{}',
        engine: engine,
        agentAppId: 'shop',
        agentBaseUrl: 'http://localhost:8080/',
      ),
    ));
    final registry = agUiRegistry(engine.services);
    expect(registry.defaults.appId, 'shop');
    expect(registry.endpoint('assistant')!.url,
        'http://localhost:8080/apps/shop/agent/assistant');
  });

  testWidgets(
      'AgUiSurface widget: static messages, events and the agent host APIs',
      (tester) async {
    final messages = readJson(
        'spec/catalogs/basic/examples/00_interactive-button.json')['messages'];
    final got = <Map<String, dynamic>>[];
    final services = ElpianServices(appId: 'widget');
    final engine = ElpianEngine(services: services);
    await tester.pumpWidget(host(engine.renderFromJson({
      'type': 'AgUiSurface',
      'key': 'w',
      'props': {'messages': messages},
      'events': {
        'aguiAction': (ElpianEvent e) =>
            got.add(Map<String, dynamic>.from(e.data['value'] as Map)),
      },
    })));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final registry = agUiRegistry(services);
    final conv = registry['static:w']!;
    expect(conv.surfaces.surfaceIds, hasLength(1));
    final s = conv.surfaces.surfaceIds.first;
    final button = conv.surfaces
        .contextFor(s)
        .definition
        .value!
        .components
        .values
        .firstWhere((c) => c.type == 'Button');
    // Tapping the rendered button dispatches the action to the node's events.
    await tester.tap(find.byWidgetPredicate((w) => w is ButtonStyleButton).first);
    await tester.pumpAndSettle();
    expect(got, hasLength(1));
    expect(got.first['sourceComponentId'], button.id);

    // Host APIs share the registry; the guest SDK's `askHost(name, [{...}])`
    // shape and a bare object both work.
    final handler = HostHandler(services: services);
    final model = jsonDecode(await handler.dispatch(
        'agui.dataModel',
        jsonEncode([
          {'conversation': 'static:w', 'surfaceId': s}
        ]))) as Map;
    expect(['object', 'null'], contains(model['type']));

    final agent = FakeAgent()
      ..chunks = [
        '{"type":"conversation","conversationId":"c9"}\n{"type":"done","stopReason":"end_turn"}\n'
      ];
    registry
      ..fetch = agent.call
      ..defaults =
          const AgUiDefaults(baseUrl: 'http://agent.test', appId: 'shop');
    final sent =
        await tester.runAsync(() async => jsonDecode(await handler.dispatch(
            'agent.send',
            jsonEncode([
              {'agent': 'assistant', 'message': 'hello'}
            ]))) as Map);
    expect(sent!['data']['value'],
        {'conversationId': 'c9', 'conversation': 'agent:assistant'});
    expect(
        agent.requests.last.url, 'http://agent.test/apps/shop/agent/assistant');

    final refused = HostHandler(services: services, onAuthorize: (_) => false);
    expect(
        jsonDecode(await refused.dispatch(
            'agent.send', '{"agent":"assistant"}'))['type'],
        'null');
    await tester.pumpWidget(const SizedBox());
  });
}
