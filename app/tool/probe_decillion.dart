// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:aseman/src/data/services/backend_capabilities.dart';
import 'package:http/http.dart' as http;

/// Checks a Decillion node against the client's contract
/// ([BackendCapabilities]): every action the app calls is asked for, signed
/// out and with an empty body. The node resolves an action before it checks
/// the caller, so only an action it does not have answers
/// `NOT_FOUND: action <namespace>/<action>`; anything else (401, 400, a
/// record not found, 200) means the node serves it.
///
///   dart run tool/probe_decillion.dart [https://preview.decillionai.com]
///
/// Exits 1 when the node lacks an action the client calls.
Future<void> main(List<String> args) async {
  final base = (args.isEmpty ? 'https://preview.decillionai.com' : args.first)
      .replaceAll(RegExp(r'/+$'), '');
  final client = http.Client();
  final pairs = [
    for (final e in BackendCapabilities.actions.entries)
      for (final a in e.value) (e.key, a),
  ];
  final missing = <String>[];
  final errors = <String>[];
  var served = 0;
  for (var i = 0; i < pairs.length; i += 12) {
    await Future.wait(
      pairs.skip(i).take(12).map((p) async {
        final (ns, action) = p;
        try {
          final resp = await client
              .post(
                Uri.parse('$base/v1/$ns/$action'),
                headers: {'Content-Type': 'application/json'},
                body: '{}',
              )
              .timeout(const Duration(seconds: 30));
          final body = resp.body;
          String error = '';
          try {
            final decoded = jsonDecode(body);
            if (decoded is Map) error = '${decoded['error'] ?? ''}';
          } catch (_) {}
          if (resp.statusCode == 404 && error.contains('action $ns/$action')) {
            missing.add('$ns.$action');
          } else if (resp.statusCode >= 500 || resp.statusCode == 0) {
            errors.add('$ns.$action: ${resp.statusCode} $error');
          } else {
            served++;
          }
        } catch (e) {
          errors.add('$ns.$action: $e');
        }
      }),
    );
  }
  client.close();
  missing.sort();
  errors.sort();
  print(
    '$base: ${pairs.length} actions in the client contract, '
    '$served served, ${missing.length} missing, ${errors.length} errors',
  );
  for (final m in missing) {
    print('  missing  $m');
  }
  for (final e in errors) {
    print('  error    $e');
  }
  exit(missing.isEmpty ? 0 : 1);
}
