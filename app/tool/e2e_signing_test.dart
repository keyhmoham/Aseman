// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:aseman/src/core/network/signing.dart';

/// End-to-end smoke test of the client signing protocol against a live
/// Aseman node. Run with the daemon up:
///   dart run tool/e2e_signing_test.dart
Future<void> main(List<String> args) async {
  const base = 'http://localhost:8080';
  final client = http.Client();

  Future<Map<String, dynamic>> call(
    String ns,
    String action,
    Map<String, dynamic> body, {
    String? token,
    String? privateKey,
  }) async {
    final path = '/v1/$ns/$action';
    final raw = jsonEncode(body);
    final headers = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    if (privateKey != null && privateKey.isNotEmpty) {
      final signer = RequestSigner(privateKey);
      headers.addAll(
          await signer.signRequest(method: 'POST', path: path, body: raw));
    }
    final resp =
        await client.post(Uri.parse('$base$path'), headers: headers, body: raw);
    final decoded = resp.body.isEmpty ? null : jsonDecode(resp.body);
    if (resp.statusCode >= 400) {
      throw StateError('$ns/$action ${resp.statusCode}: ${resp.body}');
    }
    return (decoded as Map).cast<String, dynamic>();
  }

  // 1. Register (unsigned).
  final handle = 'e2e${DateTime.now().millisecondsSinceEpoch % 100000}';
  final reg = await call('auth', 'register', {
    'handle': handle,
    'email': '$handle@x.com',
    'password': 'secret1234',
  });
  final token = reg['token'] as String;
  final priv = reg['private_key'] as String;
  final pub = reg['public_key'] as String;
  print(
      'registered $handle id=${reg['account_id']} home=${reg['home_space_id']}');

  // 2. Signed call: whoami.
  final who =
      await call('auth', 'whoami', const {}, token: token, privateKey: priv);
  print('whoami: $who');

  // 3. Signed post creation + feed.
  await call('posts', 'post_create', {'body': 'signed hello from $handle'},
      token: token, privateKey: priv);
  final feed = await call('posts', 'post_feed', {'limit': 3},
      token: token, privateKey: priv);
  print('feed count: ${(feed['posts'] as List).length}');

  // 4. Signed spaces list (home workspace).
  final spaces = await call('spaces', 'space_list', const {},
      token: token, privateKey: priv);
  print(
      'spaces: ${(spaces['spaces'] as List).map((s) => (s as Map)['name']).toList()}');

  // 5. Message ask to self (user target -> async).
  final me = reg['account_id'] as String;
  final ask = await call('message', 'ask', {'to': me, 'body': 'ping'},
      token: token, privateKey: priv);
  print('ask status: ${ask['status']}');

  print('E2E SIGNING OK — public key: $pub');
}
