import 'dart:async';
import 'dart:convert';

import 'package:aseman/src/features/tools/elpian_app/elpian_app_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const page = '/v1/proxy/0123456789abcdef0123456789abcdef/';

ElpianAppHost host(
  http.Client client, {
  void Function(Map<String, dynamic>)? onSettle,
}) =>
    ElpianAppHost(
      baseUrl: 'https://node.example/',
      page: page,
      headers: () => {'Authorization': 'Bearer person'},
      env: () => {'display': 'full'},
      settle: (r) async => onSettle?.call(r),
      client: client,
    );

dynamic unwrap(String raw) => (jsonDecode(raw) as Map)['data']['value'];

void main() {
  test('an Elpian app reaches its space and its own server through its preview only', () {
    final h = host(MockClient((_) async => http.Response('{}', 200)));
    expect(h.urlFor({'target': 'aseman', 'op': 'ask'}).toString(),
        'https://node.example${page}_aseman/api/ask');
    expect(
        h.urlFor({
          'target': 'app',
          'path': '/api/orders',
          'query': {'page': 2}
        }).toString(),
        'https://node.example${page}api/orders?page=2');
    for (final bad in [
      {'target': 'aseman', 'op': 'delete_everything'},
      {'target': 'app', 'path': '../other/x'},
      {'target': 'app', 'path': 'https://evil.example/x'},
      {'target': 'app', 'path': '_aseman/api/ask'},
      {'target': 'elsewhere', 'path': 'x'},
    ]) {
      expect(() => h.urlFor(bad), throwsFormatException, reason: '$bad');
    }
  });

  test('requests are accepted at once and settled when the answer comes', () async {
    final seen = <http.Request>[];
    final settled = Completer<Map<String, dynamic>>();
    final h = host(MockClient((req) async {
      seen.add(req);
      return http.Response(jsonEncode({'agent': 'research', 'reply': 'done'}), 200);
    }), onSettle: settled.complete);
    final raw = await h.handlers()['aseman.request']!(
        'aseman.request',
        jsonEncode(jsonEncode({
          'id': 'r1',
          'target': 'aseman',
          'op': 'ask',
          'method': 'POST',
          'body': {'agent': 'research', 'prompt': 'hi'},
          'headers': {'Authorization': 'Bearer forged', 'X-Aseman-User-Token': 'forged'},
        })));
    expect(unwrap(raw), {'accepted': true});
    final result = await settled.future;
    expect(result, {
      'id': 'r1',
      'ok': true,
      'status': 200,
      'data': {'agent': 'research', 'reply': 'done'},
    });
    expect(seen.single.headers['Authorization'], 'Bearer person');
    expect(seen.single.headers.containsKey('X-Aseman-User-Token'), isFalse);
    expect(jsonDecode(seen.single.body), {'agent': 'research', 'prompt': 'hi'});
  });

  test('failures reach the program with their message', () async {
    final h = host(MockClient((req) async => req.url.path.endsWith('ask')
        ? http.Response(jsonEncode({'error': 'insufficient funds'}), 402)
        : http.Response('nope', 500)));
    final ask = await h.perform({'target': 'aseman', 'op': 'ask', 'method': 'POST', 'body': {}},
        h.urlFor({'target': 'aseman', 'op': 'ask'}));
    expect(ask, {'ok': false, 'status': 402, 'error': 'insufficient funds'});
    // The app's own server: the status is the program's to judge.
    final app = await h.perform({'target': 'app', 'path': 'api/x'}, h.urlFor({'target': 'app', 'path': 'api/x'}));
    expect(app['ok'], isTrue);
    expect((app['data'] as Map)['status'], 500);
    expect((app['data'] as Map)['text'], 'nope');
  });

  test('a malformed request is refused without a network call', () async {
    var calls = 0;
    final h = host(MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    }));
    final raw = await h.handlers()['aseman.request']!('aseman.request', '{"target":"app"}');
    expect((unwrap(raw) as Map)['error'], isNotNull);
    final bad = await h.handlers()['aseman.request']!(
        'aseman.request', jsonEncode({'id': 'r2', 'target': 'app', 'path': '../x'}));
    expect((unwrap(bad) as Map)['status'], 400);
    expect(calls, 0);
  });

  test('an app that answers 503 is woken and asked again', () async {
    var calls = 0, wakes = 0;
    final settled = Completer<Map<String, dynamic>>();
    final h = ElpianAppHost(
      baseUrl: 'https://node.example/',
      page: '/v1/platforms/acme/app/',
      headers: () => const {},
      env: () => const {},
      settle: (r) async => settled.complete(r),
      onAsleep: () async {
        wakes++;
        return true;
      },
      client: MockClient((req) async => ++calls == 1
          ? http.Response('{"code":"WAKING"}', 503)
          : http.Response('{"items":[]}', 200)),
    );
    h.handlers()['aseman.request']!(
        'aseman.request', jsonEncode({'id': 'r1', 'target': 'app', 'path': 'api/items'}));
    final r = await settled.future;
    expect(calls, 2);
    expect(wakes, 1);
    expect(r['ok'], isTrue);
    expect(r['status'], 200);
  });
}
