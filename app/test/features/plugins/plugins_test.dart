import 'package:aseman/src/features/plugins/data/plugins_api.dart';
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

void main() {
  test('a plugin reads its scope, placement and App UI preview from the node',
      () {
    final p = PluginInfo.fromJson({
      'id': 'p2',
      'name': 'Board',
      'scope': 'space',
      'space_id': 's1',
      'owner': 'u1',
      'placement': 'desk',
      'status': 'removed',
      'preview': '/v1/proxy/0123456789abcdef0123456789abcdef/',
      'entry': 'elpian/app.js',
      'app_id': 'abc123',
      'ui': 'elpian',
    });
    expect(p.appWide, isFalse);
    expect(p.spaceId, 's1');
    expect(p.placement, PluginPlacement.desk);
    expect(p.removed, isTrue);
    expect(p.isApp, isTrue);
    expect(p.preview, startsWith('/v1/proxy/'));
    expect(p.entry, 'elpian/app.js');
    expect(p.appId, 'abc123');
    expect(PluginInfo.fromJson({'scope': 'account'}).appWide, isTrue);
    expect(PluginInfo.fromJson({'scope': 'account'}).isApp, isFalse);
    expect(PluginPlacement.parse('anything'), PluginPlacement.chat);
    expect(PluginPlacement.parse('rail'), PluginPlacement.rail);
    expect(PluginInfo.fromJson({'ui': 'web'}).web, isTrue);
  });

  test('listing asks for the space and removed plugins only when wanted',
      () async {
    final node = _Node()
      ..replies['tools.plugin_list'] = (_) => {
            'plugins': [
              {
                'id': 'p1',
                'name': 'Budget',
                'scope': 'account',
                'preview': '/v1/proxy/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
                'entry': 'elpian/app.js',
              },
              'junk',
            ]
          };
    final plugins = await node.api.list();
    expect(plugins.single.name, 'Budget');
    expect(plugins.single.isApp, isTrue);
    expect(node.calls.last.$2, isEmpty);
    await node.api.list(spaceId: 's1', removed: true);
    expect(node.calls.last.$2, {'space': 's1', 'removed': true});
  });

  test('remove and restore hit the plugin actions', () async {
    final node = _Node();
    await node.api.remove('p1');
    expect(node.calls.single.$1, 'tools.plugin_remove');
    expect(node.calls.single.$2, {'plugin': 'p1'});
    await node.api.restore('p1');
    expect(node.calls.last.$1, 'tools.plugin_restore');
    expect(node.calls.last.$2, {'plugin': 'p1'});
  });
}
