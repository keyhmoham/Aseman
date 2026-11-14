import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/network/api_client.dart';

void main() {
  test('empty body is sent as {} so Decode and signatures match the node',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final done = Completer<String>();
    final subscription = server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true}');
      await request.response.close();
      done.complete(body);
    });
    final client =
        AsemanApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    try {
      await client.call('auth', 'config');
      expect(await done.future, '{}');
    } finally {
      client.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test(
      'explicit request timeout supports a long action without changing other deadlines',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <HttpRequest>[];
    final arrived = Completer<void>();
    final subscription = server.listen((request) {
      requests.add(request);
      if (requests.length == 2) arrived.complete();
    });
    final client = AsemanApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        timeout: const Duration(milliseconds: 100));
    try {
      await expectLater(
          client.call('workflow', 'cancel'),
          throwsA(isA<ApiException>()
              .having((error) => error.code, 'code', 'TIMEOUT')));
      final longer = client.call('workflow', 'resume',
          requestTimeout: const Duration(seconds: 3));
      await arrived.future;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      requests.last.response.headers.contentType = ContentType.json;
      requests.last.response.write('{"ok":true}');
      await requests.last.response.close();
      expect((await longer).ok, true);
      expect(client.timeout, const Duration(milliseconds: 100));
    } finally {
      client.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
