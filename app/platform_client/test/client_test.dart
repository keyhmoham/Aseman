import 'dart:convert';

import 'package:aseman_platform_client/client/client_app.dart';
import 'package:aseman_platform_client/client/client_godot.dart';
import 'package:aseman_platform_client/client/config.dart';
import 'package:aseman_platform_client/client/node_api.dart';
import 'package:aseman_platform_client/client/wake.dart';
import 'package:aseman_platform_client/src/elpian/elpian.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ClientConfig', () {
    test('reads the node and platform from the frontend address', () {
      final c = ClientConfig.fromJson({'frontend': 'https://aseman.example/v1/platforms/acme/app/', 'name': 'Acme'});
      expect(c.node, 'https://aseman.example');
      expect(c.platform, 'acme');
      expect(c.frontendUrl, 'https://aseman.example/v1/platforms/acme/app/');
      expect(c.isValid, isTrue);
    });

    test('defines override the file', () {
      final c = ClientConfig.fromJson({'node': 'http://old', 'platform': 'old'},
          frontendOverride: 'http://n:8080/v1/platforms/shop/app/');
      expect(c.node, 'http://n:8080');
      expect(c.platform, 'shop');
      expect(c.name, 'shop');
    });

    test('accent colors and bad configs', () {
      expect(ClientConfig.parseColor('#4F5BD5'), 0xFF4F5BD5);
      expect(ClientConfig.parseColor('nope'), isNull);
      expect(ClientConfig.fromJson({'node': 'ftp://x', 'platform': 'acme'}).isValid, isFalse);
      expect(ClientConfig.fromJson({'node': 'https://x', 'platform': 'A!'}).isValid, isFalse);
    });
  });

  group('Godot', () {
    tearDown(() => useGodot(false));

    test('is off unless the build turned it on', () {
      expect(ClientConfig.fromJson({'frontend': 'https://n/v1/platforms/acme/app/'}).godot, isFalse);
      expect(ClientConfig.fromJson({'frontend': 'https://n/v1/platforms/acme/app/', 'godot': true}).godot, isTrue);
      expect(ClientConfig.fromJson({'godot': 'yes'}).godot, isFalse);
      expect(ClientConfig.fromJson({}, godotOverride: true).godot, isTrue);
    });

    test('off: a Scene3D gets the placeholder binding, never the plugin', () {
      useGodot(false);
      expect(resolveGodotBinding(), isA<MockGodotBinding>());
      expect(godotLive, isFalse);
      useGodot(true);
      expect(debugGodotBindingOverride, isNull);
    });
  });

  group('NodeApi', () {
    const config = ClientConfig(node: 'https://n', platform: 'acme', name: 'Acme');

    test('wakes through the platform door, signed in or not', () async {
      final seen = <http.Request>[];
      final api = NodeApi(config, client: MockClient((req) async {
        seen.add(req);
        return http.Response(jsonEncode({'state': 'waking', 'ready': false, 'retry_after_ms': 1500}), 200);
      }));
      api.session = const Session(token: 'ended', accountId: 'a1', handle: 'sam');
      final report = await api.wake(wait: const Duration(seconds: 5));
      expect(seen.single.url.toString(), 'https://n/v1/platforms/acme/app/_decillion/wake?wait=5');
      expect(seen.single.method, 'POST');
      expect(seen.single.headers.containsKey('Authorization'), isFalse);
      expect(report.state, 'waking');
      expect(report.retryAfter, const Duration(milliseconds: 1500));
    });

    test('signs in to the platform and keeps the session', () async {
      SharedPreferences.setMockInitialValues({});
      late Map<String, dynamic> body;
      final api = NodeApi(config, client: MockClient((req) async {
        body = (jsonDecode(req.body) as Map).cast<String, dynamic>();
        return http.Response(jsonEncode({'token': 't1', 'account_id': 'a1', 'handle': 'sam'}), 200);
      }));
      final s = await api.signIn('sam', 'pw');
      expect(body['platform'], 'acme');
      expect(s.handle, 'sam');
      expect(api.authHeaders()['Authorization'], 'Bearer t1');
      await Future<void>.delayed(Duration.zero);
      final again = NodeApi(config);
      await again.restore();
      expect(again.session?.token, 't1');
    });

    test('reports the node\'s errors', () async {
      final api = NodeApi(config,
          client: MockClient((req) async => http.Response(jsonEncode({'error': 'wrong password', 'code': 'UNAUTHENTICATED'}), 401)));
      await expectLater(api.signIn('sam', 'x'), throwsA(isA<NodeException>().having((e) => e.message, 'message', 'wrong password')));
    });
  });

  group('WakeController', () {
    test('polls until the computer answers, once for everyone', () async {
      var calls = 0;
      final wake = WakeController(({Duration wait = Duration.zero}) async {
        calls++;
        return calls < 3
            ? const WakeReport(state: 'waking', retryAfter: Duration(milliseconds: 1))
            : const WakeReport(state: 'ready');
      });
      final results = await Future.wait([wake.ensureAwake(), wake.ensureAwake()]);
      expect(results, [true, true]);
      expect(calls, 3);
      expect(wake.phase, WakePhase.ready);
      // Fresh: no new wake.
      expect(await wake.ensureAwake(), isTrue);
      expect(calls, 3);
      // Forced (the frontend answered 503): it asks again.
      expect(await wake.ensureAwake(force: true), isTrue);
      expect(calls, 4);
    });

    test('a failed wake says why', () async {
      final wake = WakeController(
          ({Duration wait = Duration.zero}) async => const WakeReport(state: 'failed', error: 'out of funds'));
      expect(await wake.ensureAwake(), isFalse);
      expect(wake.phase, WakePhase.failed);
      expect(wake.error, 'out of funds');
    });
  });

  testWidgets('a platform with no frontend yet says so', (tester) async {
    const config = ClientConfig(node: 'https://n', platform: 'acme', name: 'Acme');
    final api = NodeApi(config, client: MockClient((req) async {
      return http.Response(jsonEncode({'platform': {'slug': 'acme', 'name': 'Acme Shop'}, 'frontend': null}), 200);
    }));
    var wakes = 0;
    final wake = WakeController(({Duration wait = Duration.zero}) async {
      wakes++;
      return const WakeReport(state: 'ready');
    });
    await tester.pumpWidget(PlatformClientApp(api: api, wake: wake));
    await tester.pumpAndSettle();
    expect(find.text('Acme Shop is not open yet'), findsOneWidget);
    expect(wakes, 0);
  });

  testWidgets('a published frontend loads its program after the wake, as the person', (tester) async {
    const config = ClientConfig(node: 'https://n', platform: 'acme', name: 'Acme');
    final asked = <String>[];
    var asleep = true;
    final api = NodeApi(config, client: MockClient((req) async {
      asked.add('${req.method} ${req.url.path} ${req.headers['Authorization'] ?? '-'}');
      if (req.url.path == '/v1/developer/platform_frontend') {
        return http.Response(
            jsonEncode({
              'platform': {'slug': 'acme', 'name': 'Acme'},
              'frontend': {'ui': 'elpian', 'entry': 'elpian/app.js', 'url': '/v1/platforms/acme/app/'}
            }),
            200);
      }
      if (asleep) {
        // The computer fell asleep between the wake and the program's load.
        asleep = false;
        return http.Response('{"code":"WAKING"}', 503);
      }
      return http.Response('/* program */', 200);
    }));
    api.session = const Session(token: 'tok', accountId: 'a1', handle: 'sam');
    var wakes = 0;
    final wake = WakeController(({Duration wait = Duration.zero}) async {
      wakes++;
      return const WakeReport(state: 'ready');
    });
    await tester.pumpWidget(PlatformClientApp(api: api, wake: wake));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(asked, contains('GET /v1/platforms/acme/app/elpian/app.js Bearer tok'));
    expect(asked.where((a) => a.contains('elpian/app.js')).length, 2);
    expect(wakes, 2); // on open, and again when the program's load found it asleep
  });

  testWidgets('a session that ended opens the frontend as a visitor', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const config = ClientConfig(node: 'https://n', platform: 'acme', name: 'Acme');
    final program = <String>[];
    final api = NodeApi(config, client: MockClient((req) async {
      if (req.url.path == '/v1/developer/platform_frontend') {
        return http.Response(
            jsonEncode({
              'platform': {'slug': 'acme', 'name': 'Acme'},
              'frontend': {'ui': 'elpian', 'entry': 'elpian/app.js', 'url': '/v1/platforms/acme/app/'}
            }),
            200);
      }
      program.add(req.headers['Authorization'] ?? '-');
      return req.headers.containsKey('Authorization')
          ? http.Response('{"error":"session expired"}', 401)
          : http.Response('/* program */', 200);
    }));
    api.session = const Session(token: 'old', accountId: 'a1', handle: 'sam');
    final wake = WakeController(({Duration wait = Duration.zero}) async => const WakeReport(state: 'ready'));
    await tester.pumpWidget(PlatformClientApp(api: api, wake: wake));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(program, ['Bearer old', '-']);
    expect(api.session, isNull);
  });

  testWidgets('opening the client wakes the platform first', (tester) async {
    const config = ClientConfig(node: 'https://n', platform: 'acme', name: 'Acme');
    final api = NodeApi(config, client: MockClient((req) async {
      return http.Response(
          jsonEncode({
            'platform': {'slug': 'acme', 'name': 'Acme'},
            'frontend': {'ui': 'elpian', 'entry': 'elpian/app.js', 'url': '/v1/platforms/acme/app/'}
          }),
          200);
    }));
    final wake = WakeController(({Duration wait = Duration.zero}) async =>
        const WakeReport(state: 'failed', error: 'the publisher is out of funds'));
    await tester.pumpWidget(PlatformClientApp(api: api, wake: wake));
    await tester.pumpAndSettle();
    expect(find.text('Acme could not wake up'), findsOneWidget);
    expect(find.text('the publisher is out of funds'), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
