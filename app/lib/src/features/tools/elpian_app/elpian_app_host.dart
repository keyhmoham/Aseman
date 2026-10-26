import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../elpian/elpian.dart';
import '../elpian/host_values.dart';

/// The host an Elpian app runs against: an App UI whose frontend is an
/// Elpian program (deploy/sandbox-computer/appui/elpian), served from the
/// space's sandbox through its preview gateway ([page], `/v1/proxy/<id>/`).
///
/// The program's SDK (`aseman-elpian.js`) speaks this protocol:
///
///   * `aseman.env` → `{display, theme: {mode, accent, colors}, user, space,
///     room, title}`
///   * `aseman.request` `{id, target, op | path, method, query, body,
///     headers, timeoutMs}` → `{accepted}` at once; the answer comes later
///     through [settle] (the program's `__asemanSettle`) as `{id, ok, status,
///     data, error}`:
///       - target `aseman`: the space's page API, `<page>_aseman/api/<op>`
///         (agents, apps), as the person using the app;
///       - target `app`: the app's own server, `<page><path>`, which sees
///         that person too (the gateway adds their token).
///   * `aseman.compact` summary / `aseman.expand`: the phone widget.
///
/// Requests are asynchronous because a QuickJS host call cannot wait: the
/// program keeps drawing while an agent works.
class ElpianAppHost {
  ElpianAppHost({
    required this.baseUrl,
    required this.page,
    required this.headers,
    required this.settle,
    required this.env,
    http.Client? client,
    this.onCompact,
    this.onExpand,
  }) : _client = client ?? http.Client();

  /// The node, e.g. `https://node.example`.
  final String baseUrl;

  /// The app's preview gateway path, `/v1/proxy/<id>/`.
  final String page;

  /// The signed-in person's credentials for the node.
  final Map<String, String> Function() headers;

  /// Hands an answer back to the program.
  final Future<void> Function(Map<String, dynamic> result) settle;

  /// How the app is shown and themed now.
  final Map<String, dynamic> Function() env;

  final void Function(Map<String, dynamic> summary)? onCompact;
  final void Function()? onExpand;

  final http.Client _client;
  bool _disposed = false;

  /// The page API ops a program may call.
  static const ops = {
    'context',
    'tools',
    'microtools',
    'call',
    'agents',
    'ask',
    'frontend',
    'show',
  };

  Map<String, HostCallHandler> handlers() => {
        'aseman.env': (_, __) => HostValues.reply('object', env()),
        'aseman.request': _request,
        'aseman.compact': _compact,
        'aseman.expand': (_, __) {
          onExpand?.call();
          return HostValues.reply('bool', onExpand != null);
        },
      };

  /// Stops answering: the program is gone.
  void dispose() {
    _disposed = true;
    _client.close();
  }

  FutureOr<String> _request(String apiName, String payload) {
    final req = decodeRequest(payload);
    final id = '${req?['id'] ?? ''}';
    if (req == null || id.isEmpty) {
      return HostValues.reply('object', {'error': 'aseman.request needs {id, target, op or path}'});
    }
    final Uri url;
    try {
      url = urlFor(req);
    } on FormatException catch (e) {
      return HostValues.reply('object', {'error': e.message, 'status': 400});
    }
    unawaited(perform(req, url).then((result) async {
      if (_disposed) return;
      await settle({'id': id, ...result});
    }));
    return HostValues.reply('object', {'accepted': true});
  }

  FutureOr<String> _compact(String apiName, String payload) {
    final summary = decodeRequest(payload);
    if (summary == null) {
      return HostValues.error('invalid_argument', 'aseman.compact takes a summary object');
    }
    onCompact?.call(summary);
    return HostValues.reply('bool', true);
  }

  /// A request object from a host call's payload (JSON, possibly encoded
  /// twice by the bridge).
  static Map<String, dynamic>? decodeRequest(String payload) {
    dynamic v = HostValues.decode(payload);
    if (v is String) v = HostValues.decode(v);
    if (v is List && v.isNotEmpty) v = v.first;
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  /// Where a request goes. Only the app's own preview: never another site,
  /// never another app.
  Uri urlFor(Map<String, dynamic> req) {
    final root = '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}$page';
    String rest;
    switch ('${req['target'] ?? ''}') {
      case 'aseman':
        final op = '${req['op'] ?? ''}';
        if (!ops.contains(op)) {
          throw FormatException('unknown Aseman op "$op"');
        }
        rest = '_aseman/api/$op';
      case 'app':
        rest = '${req['path'] ?? ''}'.replaceFirst(RegExp(r'^/+'), '');
        final segments = rest.split('?').first.split('/');
        if (rest.contains('://') ||
            rest.contains('\\') ||
            segments.any((s) => s == '..' || s == '.') ||
            rest.startsWith('_aseman/')) {
          throw FormatException('"$rest" is not a path of this app');
        }
      default:
        throw const FormatException('target is "aseman" or "app"');
    }
    final url = Uri.parse(root + rest);
    final query = req['query'];
    if (query is Map && query.isNotEmpty) {
      return url.replace(queryParameters: {
        ...url.queryParameters,
        for (final e in query.entries)
          if (e.value != null)
            '${e.key}': e.value is String ? e.value as String : jsonEncode(e.value),
      });
    }
    return url;
  }

  /// Runs a request and describes the outcome for the program.
  Future<Map<String, dynamic>> perform(Map<String, dynamic> req, Uri url) async {
    final method = '${req['method'] ?? 'GET'}'.toUpperCase();
    final ms = (req['timeoutMs'] as num?)?.toInt() ?? 120000;
    final timeout = Duration(milliseconds: ms.clamp(1000, 600000).toInt());
    final hasBody = req.containsKey('body') && method != 'GET';
    final body = req['body'];
    final extra = req['headers'] is Map
        ? (req['headers'] as Map).map((k, v) => MapEntry('$k', '$v'))
        : const <String, String>{};
    final h = <String, String>{
      // The app's own headers never override who the person is.
      for (final e in extra.entries)
        if (!_reserved(e.key)) e.key: e.value,
      ...headers(),
      if (hasBody) 'Content-Type': 'application/json',
    };
    try {
      final request = http.Request(method, url)..headers.addAll(h);
      if (hasBody) {
        request.body = body is String ? body : jsonEncode(body);
      }
      final streamed = await _client.send(request).timeout(timeout);
      final res = await http.Response.fromStream(streamed).timeout(timeout);
      final text = utf8.decode(res.bodyBytes, allowMalformed: true);
      final json = _json(text);
      if (req['target'] == 'app') {
        // The app's server answered: the program decides what a status means.
        return {
          'ok': true,
          'status': res.statusCode,
          'data': {
            'status': res.statusCode,
            'ok': res.statusCode >= 200 && res.statusCode < 300,
            'json': json,
            'text': text.length > 1 << 20 ? text.substring(0, 1 << 20) : text,
            'contentType': res.headers['content-type'] ?? '',
          },
        };
      }
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return {'ok': true, 'status': res.statusCode, 'data': json};
      }
      final message = json is Map
          ? '${json['error'] ?? json['message'] ?? 'request failed'}'
          : 'request failed (HTTP ${res.statusCode})';
      return {'ok': false, 'status': res.statusCode, 'error': message};
    } on TimeoutException {
      return {'ok': false, 'status': 504, 'error': 'timed out'};
    } catch (e) {
      return {'ok': false, 'status': 0, 'error': '$e'};
    }
  }

  static bool _reserved(String name) {
    final n = name.toLowerCase();
    return n == 'authorization' || n == 'cookie' || n.startsWith('x-aseman-');
  }

  static dynamic _json(String text) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }
}
