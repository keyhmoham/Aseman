import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/features/tools/data/tools_api.dart';
import 'package:tradera/src/features/tools/mcp_app/mcp_app_frame_io.dart'
    show withMcpShim;
import 'package:tradera/src/features/tools/mcp_app/mcp_app_host.dart';
import 'package:tradera/src/features/tools/presentation/mcp_app_view.dart';

void main() {
  group('McpAppHost', () {
    late List<Map<String, dynamic>> sent;
    late List<(String, Map<String, dynamic>)> rpcs;
    late Completer<Map<String, dynamic>> result;
    late McpAppHost host;
    final opened = <Uri>[];

    setUp(() {
      sent = [];
      rpcs = [];
      result = Completer();
      host = McpAppHost(
        send: sent.add,
        rpc: (method, params) async {
          rpcs.add((method, params));
          return {'content': <Object>[], 'echo': method};
        },
        arguments: const {'elements': '[]'},
        result: result.future,
        theme: 'dark',
        openLink: (u) async => opened.add(u),
      );
    });

    test('answers the handshake, then hands over the input and the result',
        () async {
      await host.receive({
        'jsonrpc': '2.0',
        'id': 0,
        'method': 'ui/initialize',
        'params': {
          'protocolVersion': '2025-11-21',
          'appInfo': {'name': 'X'}
        },
      });
      expect(sent.single['id'], 0);
      final init = sent.single['result'] as Map;
      expect(init['protocolVersion'], '2025-11-21');
      expect((init['hostContext'] as Map)['theme'], 'dark');

      await host.receive(
          {'jsonrpc': '2.0', 'method': 'ui/notifications/initialized'});
      expect(sent[1]['method'], 'ui/notifications/tool-input');
      expect((sent[1]['params'] as Map)['arguments'], {'elements': '[]'});

      result.complete({
        'structuredContent': {'checkpointId': 'c1'}
      });
      await Future<void>.delayed(Duration.zero);
      expect(sent[2]['method'], 'ui/notifications/tool-result');
      expect((sent[2]['params'] as Map)['structuredContent'],
          {'checkpointId': 'c1'});
    });

    test('relays the app\'s calls to its server and opens links', () async {
      await host.receive({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'tools/call',
        'params': {
          'name': 'save_checkpoint',
          'arguments': {'id': 'c1'}
        },
      });
      expect(rpcs.single.$1, 'tools/call');
      expect(rpcs.single.$2['name'], 'save_checkpoint');
      expect(sent.single, {
        'jsonrpc': '2.0',
        'id': 7,
        'result': {'content': <Object>[], 'echo': 'tools/call'}
      });

      await host.receive({
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'ui/open-link',
        'params': {'url': 'https://excalidraw.com/#json=1'},
      });
      expect(opened.single.host, 'excalidraw.com');
      await host.receive({
        'jsonrpc': '2.0',
        'id': 9,
        'method': 'ui/open-link',
        'params': {'url': 'javascript:alert(1)'},
      });
      expect(opened, hasLength(1));
    });

    test('refuses what it does not know; ignores responses and junk', () async {
      await host.receive({'jsonrpc': '2.0', 'id': 3, 'method': 'sampling/x'});
      expect((sent.single['error'] as Map)['code'], -32601);
      await host.receive({'jsonrpc': '2.0', 'id': 4, 'result': <String, Object>{}});
      await host.receive('not json-rpc');
      expect(sent, hasLength(1));
    });
  });

  test('the web-view shim goes first in the head', () {
    final html = withMcpShim('<html><head><title>x</title></head></html>');
    expect(html.indexOf('TraderaMcpHost'), lessThan(html.indexOf('<title>')));
    expect(html.indexOf('<head>'), lessThan(html.indexOf('TraderaMcpHost')));
  });

  testWidgets('a window runs the tool\'s app with its call', (tester) async {
    final calls = <(String, Map<String, dynamic>)>[];
    final api = ToolsApi((ns, action, body, {timeout}) async {
      calls.add((action, body));
      final method = body['method'];
      if (method == 'app') {
        return {
          'uri': 'ui://excalidraw/mcp-app.html',
          'resource': {
            'contents': [
              {
                'uri': 'ui://excalidraw/mcp-app.html',
                'mimeType': 'text/html;profile=mcp-app',
                'text': '<html><body>app</body></html>'
              }
            ]
          }
        };
      }
      return {
        'structuredContent': {'checkpointId': 'c9'}
      };
    });
    String? html;
    void Function(Object?)? toHost;
    final toApp = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: McpAppView(
          api: api,
          botId: 'bot1',
          spaceId: 'space1',
          microtool: 'create_view',
          args: const {'elements': '[1]'},
          frame: ({key, required html, required onMessage, required onReady}) {
            return _Frame(
                key: key,
                onCreated: () {
                  toHost = onMessage;
                  onReady(toApp.add);
                },
                child: Text(html));
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    html = tester.widget<Text>(find.byType(Text)).data;
    expect(html, contains('app'));
    expect(calls.first.$2['method'], 'app');
    expect(calls.first.$2['params'], {'microtool': 'create_view'});

    toHost!({
      'jsonrpc': '2.0',
      'id': 0,
      'method': 'ui/initialize',
      'params': {'protocolVersion': '2025-11-21'}
    });
    // The app waits for the handshake's answer before saying it is ready.
    await tester.pumpAndSettle();
    toHost!({'jsonrpc': '2.0', 'method': 'ui/notifications/initialized'});
    await tester.pumpAndSettle();
    expect(toApp.map((m) => m['method'] ?? 'reply'), [
      'reply',
      'ui/notifications/tool-input',
      'ui/notifications/tool-result'
    ]);
    final call = calls.firstWhere((c) => c.$2['method'] == 'tools/call');
    expect(call.$2['params'], {
      'name': 'create_view',
      'arguments': {'elements': '[1]'}
    });
    expect((toApp.last['params'] as Map)['structuredContent'],
        {'checkpointId': 'c9'});
  });
}

class _Frame extends StatefulWidget {
  const _Frame({super.key, required this.onCreated, required this.child});
  final VoidCallback onCreated;
  final Widget child;

  @override
  State<_Frame> createState() => _FrameState();
}

class _FrameState extends State<_Frame> {
  @override
  void initState() {
    super.initState();
    widget.onCreated();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
