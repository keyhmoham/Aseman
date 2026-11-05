import 'package:aseman/src/features/gadgets/data/gadgets_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// A node that records the gadget actions it is asked and answers from
/// [replies] (keyed `namespace.action`).
class _Node {
  final calls = <(String, Map<String, dynamic>)>[];
  final replies = <String, dynamic Function(Map<String, dynamic>)>{};

  late final api = GadgetsApi((namespace, action, body, {timeout}) async {
    final name = '$namespace.$action';
    calls.add((name, body));
    final reply = replies[name];
    if (reply == null) return <String, dynamic>{};
    return reply(body);
  });
}

void main() {
  test('a gadget reads its scope, placement and App UI preview from the node',
      () {
    final p = GadgetInfo.fromJson({
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
    expect(p.placement, GadgetPlacement.desk);
    expect(p.removed, isTrue);
    expect(p.isApp, isTrue);
    expect(p.preview, startsWith('/v1/proxy/'));
    expect(p.entry, 'elpian/app.js');
    expect(p.appId, 'abc123');
    expect(GadgetInfo.fromJson({'scope': 'account'}).appWide, isTrue);
    expect(GadgetInfo.fromJson({'scope': 'account'}).isApp, isFalse);
    expect(GadgetPlacement.parse('anything'), GadgetPlacement.chat);
    expect(GadgetPlacement.parse('rail'), GadgetPlacement.rail);
    expect(GadgetInfo.fromJson({'ui': 'web'}).web, isTrue);
  });

  test('listing asks for the space when wanted', () async {
    final node = _Node()
      ..replies['tools.gadget_list'] = (_) => {
            'gadgets': [
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
    final gadgets = await node.api.list();
    expect(gadgets.single.name, 'Budget');
    expect(gadgets.single.isApp, isTrue);
    expect(node.calls.last.$2, isEmpty);
    await node.api.list(spaceId: 's1');
    expect(node.calls.last.$2, {'space': 's1'});
  });

  test('remove hits the gadget action', () async {
    final node = _Node();
    await node.api.remove('p1');
    expect(node.calls.single.$1, 'tools.gadget_remove');
    expect(node.calls.single.$2, {'gadget': 'p1'});
  });
}
