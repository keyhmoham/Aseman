import 'dart:convert';

import 'package:aseman/src/features/plugins/data/plugins_api.dart';
import 'package:aseman/src/features/plugins/runtime/plugin_host.dart';
import 'package:aseman/src/features/plugins/runtime/plugin_runtime.dart';
import 'package:aseman/src/features/tools/domain/tool_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// A node that records the plugin actions it is asked and answers from
/// [replies] (keyed `namespace.action`).
class _Node {
  final calls = <(String, Map<String, dynamic>)>[];
  final replies = <String, dynamic Function(Map<String, dynamic>)>{};

  late final api = PluginsApi((namespace, action, body, {timeout}) async {
    final name = '$namespace.$action';
    calls.add((name, body));
    final reply = replies[name];
    if (reply == null) return <String, dynamic>{};
    return reply(body);
  });
}

dynamic _value(String raw) => (jsonDecode(raw) as Map)['data']['value'];

const _appWide = PluginInfo(
    id: 'p1', name: 'Budget', appWide: true, ownerId: 'u1', placement: PluginPlacement.page);
const _spaced = PluginInfo(
    id: 'p2', name: 'Board', spaceId: 's1', ownerId: 'u1', placement: PluginPlacement.desk);

void main() {
  test('a plugin reads its scope, placement and state from the node', () {
    final p = PluginInfo.fromJson({
      'id': 'p2',
      'name': 'Board',
      'scope': 'space',
      'space_id': 's1',
      'owner': 'u1',
      'placement': 'desk',
      'permissions': ['spaces.message_list'],
      'status': 'removed',
    });
    expect(p.appWide, isFalse);
    expect(p.spaceId, 's1');
    expect(p.placement, PluginPlacement.desk);
    expect(p.permissions, ['spaces.message_list']);
    expect(p.removed, isTrue);
    expect(PluginInfo.fromJson({'scope': 'account'}).appWide, isTrue);
    expect(PluginPlacement.parse('anything'), PluginPlacement.chat);
    expect(PluginPlacement.parse('panel'), PluginPlacement.chat);
    expect(PluginPlacement.parse('rail'), PluginPlacement.rail);
  });

  test('listing asks for the space and removed plugins only when wanted', () async {
    final node = _Node()
      ..replies['tools.plugin_list'] = (_) => {
            'plugins': [
              {'id': 'p1', 'name': 'Budget', 'scope': 'account'},
              'junk',
            ]
          };
    final plugins = await node.api.list();
    expect(plugins.single.name, 'Budget');
    expect(node.calls.last.$2, isEmpty);
    await node.api.list(spaceId: 's1', removed: true);
    expect(node.calls.last.$2, {'space': 's1', 'removed': true});
  });

  test("tool.call reaches the plugin's own backend through the plugin gate", () async {
    final node = _Node()
      ..replies['tools.plugin_invoke'] = (body) => {
            'result': {
              'structuredContent': {'echo': (body['payload'] as Map)['x']}
            }
          };
    final host = PluginHost(node.api, plugin: _spaced, spaceId: 's1', roomId: 'r1');
    final raw = await host.handlers()['tool.call']!(
        'tool.call',
        jsonEncode([
          'add',
          {'x': 5}
        ]));
    expect(_value(raw), {'echo': 5});
    expect(node.calls.single.$1, 'tools.plugin_invoke');
    expect(node.calls.single.$2,
        {'plugin': 'p2', 'function': 'add', 'payload': {'x': 5}, 'room': 'r1'});
    // The object form names the microtool too.
    await host.handlers()['server.call']!(
        'server.call', jsonEncode({'microtool': 'list', 'args': {}}));
    expect(node.calls.last.$2['function'], 'list');
    final bad = await host.handlers()['tool.call']!('tool.call', '');
    expect(_value(bad)['error']['code'], 'invalid_argument');
  });

  test('aseman.call is a platform action, as the person, through plugin_call', () async {
    final node = _Node()
      ..replies['tools.plugin_call'] = (_) => {'ok': true};
    final host = PluginHost(node.api, plugin: _appWide);
    final raw = await host.handlers()['aseman.call']!(
        'aseman.call',
        jsonEncode([
          'themes',
          'apply',
          {'theme': 't1'}
        ]));
    expect(_value(raw), {'ok': true});
    expect(node.calls.single.$2,
        {'plugin': 'p1', 'namespace': 'themes', 'action': 'apply', 'body': {'theme': 't1'}});
    await host.handlers()['aseman.call']!('aseman.call',
        jsonEncode({'namespace': 'spaces', 'action': 'space_list', 'body': {}}));
    expect(node.calls.last.$2['action'], 'space_list');
    final bad = await host.handlers()['aseman.call']!('aseman.call', jsonEncode(['themes']));
    expect(_value(bad)['error']['code'], 'invalid_argument');
    expect(node.calls, hasLength(2));
  });

  test('a refused call is an error the program can read', () async {
    final node = _Node()
      ..replies['tools.plugin_call'] = (_) => throw Exception('not declared');
    final host = PluginHost(node.api, plugin: _appWide);
    final raw = await host.handlers()['aseman.call']!(
        'aseman.call', jsonEncode(['admin', 'health', {}]));
    expect(_value(raw)['error']['code'], 'platform_error');
  });

  test("aseman.context says where the plugin is and whose it is", () async {
    final node = _Node();
    final wide = PluginHost(node.api, plugin: _appWide, spaceId: 'elsewhere', roomId: 'r9', userId: 'u1');
    expect(_value(await wide.handlers()['aseman.context']!('aseman.context', '')), {
      'plugin': 'p1',
      'name': 'Budget',
      'scope': 'account',
      'space': 'elsewhere',
      'room': 'r9',
      'user': 'u1',
      'display': 'full',
    });
    // A space plugin is always in its own space.
    final spaced = PluginHost(node.api, plugin: _spaced, spaceId: 'elsewhere');
    expect(_value(await spaced.handlers()['aseman.context']!('aseman.context', ''))['space'], 's1');
  });

  test('a frontend says when its tool is a plugin', () {
    final payload = ToolFrontendPayload.fromJson({
      'mode': 'static',
      'plugin': {'id': 'p1', 'name': 'Budget', 'scope': 'account', 'placement': 'desk'},
    });
    expect(PluginInfo.fromJson(payload.plugin!).placement, PluginPlacement.desk);
    expect(ToolFrontendPayload.fromJson({'mode': 'static'}).plugin, isNull);
  });

  test('a web plugin says so, and its frontend runs on the web runtime', () {
    expect(PluginInfo.fromJson({'id': 'p', 'ui': 'web'}).web, isTrue);
    expect(PluginInfo.fromJson({'id': 'p', 'ui': 'elpian'}).web, isFalse);
    expect(PluginInfo.fromJson({'id': 'p'}).web, isFalse);
    expect(ToolRuntime.parse('web'), ToolRuntime.web);
  });

  test('Aseman.plugin requests are accepted now and answered through settle',
      () async {
    final node = _Node()
      ..replies['tools.plugin_invoke'] = (body) => {
            'result': {
              'structuredContent': {'value': (body['payload'] as Map)['key']}
            }
          }
      ..replies['tools.plugin_call'] = (_) => {'ok': true};
    final settled = <Map<String, dynamic>>[];
    final host = PluginHost(node.api,
        plugin: _spaced,
        spaceId: 's1',
        roomId: 'r1',
        userId: 'u1',
        settle: (r) async => settled.add(r),
        env: () => {'theme': {'mode': 'dark'}});
    final handlers = host.handlers();
    Future<void> request(Map<String, dynamic> req) async {
      final raw = await handlers['aseman.request']!(
          'aseman.request', jsonEncode(jsonEncode(req)));
      expect(_value(raw), {'accepted': true});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    await request({
      'id': 'p1',
      'target': 'plugin',
      'op': 'invoke',
      'body': {
        'function': 'get',
        'args': {'key': 'items'}
      }
    });
    expect(settled.last['id'], 'p1');
    expect(settled.last['ok'], isTrue);
    expect(settled.last['data'], {'value': 'items'});
    expect(node.calls.last.$2,
        {'plugin': 'p2', 'function': 'get', 'payload': {'key': 'items'}, 'room': 'r1'});

    await request({
      'id': 'p2',
      'target': 'plugin',
      'op': 'call',
      'body': {'namespace': 'spaces', 'action': 'message_list', 'body': {}}
    });
    expect(settled.last['ok'], isTrue);
    expect(node.calls.last.$1, 'tools.plugin_call');

    await request({'id': 'p3', 'target': 'plugin', 'op': 'context'});
    expect((settled.last['data'] as Map)['space'], 's1');

    // The SDK's page API is not a plugin's: refused with a hint.
    await request({'id': 'p4', 'target': 'app', 'path': 'api/x'});
    expect(settled.last['ok'], isFalse);
    expect('${settled.last['error']}', contains('Aseman.plugin'));

    final env = _value(await handlers['aseman.env']!('aseman.env', ''));
    expect(env['theme'], {'mode': 'dark'});
    expect(env['kind'], 'plugin');

    // After the screen is gone nothing is delivered.
    host.dispose();
    final before = settled.length;
    await request({'id': 'p5', 'target': 'plugin', 'op': 'context'});
    expect(settled.length, before);
  });

  test('without settle a request is refused, not lost', () async {
    final host = PluginHost(_Node().api, plugin: _appWide);
    final raw = await host.handlers()['aseman.request']!(
        'aseman.request', jsonEncode({'id': 'x', 'target': 'plugin', 'op': 'context'}));
    expect(_value(raw)['error'], isNotNull);
  });

  test('a backend failure is an answer the screen can read', () async {
    final node = _Node()
      ..replies['tools.plugin_invoke'] = (_) => throw Exception('boom');
    final host = PluginHost(node.api, plugin: _appWide);
    final r = await host.perform('invoke', {'function': 'add'});
    expect(r['ok'], isFalse);
    expect('${r['error']}', contains('boom'));
    expect((await host.perform('nope', {}))['ok'], isFalse);
    expect((await host.perform('invoke', {}))['ok'], isFalse);
  });

  test('a web plugin gets the frame policy, its env and the bridge first', () {
    final doc = PluginRuntime.webDocument(
        '<!doctype html><html><head><title>t</title></head><body></body></html>',
        {'theme': {'mode': 'dark', 'name': '</script>'}},
        'window.Aseman = {};');
    final head = doc.indexOf('<head>') + '<head>'.length;
    expect(
        doc.substring(head),
        startsWith(
            '<meta http-equiv="Content-Security-Policy" content="${PluginRuntime.webPolicy}">'));
    expect(PluginRuntime.webPolicy, contains("connect-src 'none'"));
    expect(doc, contains('window.__asemanInitialEnv='));
    expect(doc, isNot(contains('"</script>"')), reason: 'the env cannot end its script');
    expect(doc.indexOf('window.Aseman = {};'), lessThan(doc.indexOf('<title>')));
    // A fragment becomes a document.
    expect(PluginRuntime.webDocument('<canvas></canvas>', const {}, ''),
        startsWith('<!doctype html><html><head><meta'));
  });
}

