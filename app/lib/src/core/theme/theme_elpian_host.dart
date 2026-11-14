import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/services/aseman_service.dart';
import '../../elpian/vm/elpian_vm.dart';
import '../../features/tools/elpian/host_values.dart';

/// Host bridge for theme-declared Elpian programs (UI islands / slot panels).
///
/// Speaks the same `aseman.*` protocol as [ElpianAppHost], but routes
/// `target: "core"` (and core-shaped `decillion` calls) through the signed-in
/// [AsemanService] client — so theme islands can use the full platform API.
class ThemeElpianHost {
  ThemeElpianHost({
    required this.service,
    required this.env,
    required this.settle,
    this.slot = '',
    this.spaceId = '',
    this.roomId = '',
    this.onNavigate,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final AsemanService service;
  final Map<String, dynamic> Function() env;
  final Future<void> Function(Map<String, dynamic> result) settle;
  final String slot;
  final String spaceId;
  final String roomId;
  final FutureOr<void> Function(Map<String, dynamic> intent)? onNavigate;
  final http.Client _client;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _client.close();
  }

  Map<String, HostCallHandler> handlers() => {
        'decillion.env': (_, __) => HostValues.reply('object', {
              ...env(),
              'slot': slot,
              'kind': 'theme',
            }),
        'decillion.request': _request,
        'decillion.navigate': _navigate,
        'decillion.compact': (_, __) => HostValues.reply('bool', false),
        'decillion.expand': (_, __) => HostValues.reply('bool', false),
      };

  FutureOr<String> _navigate(String apiName, String payload) {
    final req = _decodeMap(payload) ?? const {};
    final cb = onNavigate;
    if (cb == null) {
      return HostValues.error('unsupported', 'navigate is not wired here');
    }
    unawaited(Future.sync(() => cb(req)));
    return HostValues.reply('bool', true);
  }

  FutureOr<String> _request(String apiName, String payload) {
    final req = _decodeMap(payload);
    final id = '${req?['id'] ?? ''}';
    if (req == null || id.isEmpty) {
      return HostValues.reply('object', {
        'error': 'decillion.request needs {id, target, …}',
      });
    }
    unawaited(_perform(req).then((result) async {
      if (_disposed) return;
      await settle({'id': id, ...result});
    }));
    return HostValues.reply('object', {'accepted': true});
  }

  Future<Map<String, dynamic>> _perform(Map<String, dynamic> req) async {
    final target = '${req['target'] ?? ''}'.toLowerCase().trim();
    try {
      switch (target) {
        case 'core':
        case 'api':
        case 'platform':
          return await _coreCall(req);
        case 'decillion':
          // Theme panels have no sandbox preview page; map page ops that are
          // really platform actions onto the core client, else reject.
          return await _asemanOp(req);
        case 'http':
        case 'url':
          return await _httpFetch(req);
        default:
          return {
            'ok': false,
            'status': 400,
            'error':
                'theme panel target must be "core", "decillion", or "http" (got "$target")',
          };
      }
    } catch (e) {
      return {'ok': false, 'status': 0, 'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> _coreCall(Map<String, dynamic> req) async {
    var namespace = '${req['namespace'] ?? req['ns'] ?? ''}'.trim();
    var action = '${req['action'] ?? req['op'] ?? ''}'.trim();
    final path = '${req['path'] ?? ''}'.trim();
    if ((namespace.isEmpty || action.isEmpty) && path.isNotEmpty) {
      final parts = path.replaceFirst(RegExp(r'^/+'), '').split('/');
      if (parts.length >= 2) {
        namespace = parts[0];
        action = parts.sublist(1).join('/');
      }
    }
    if (namespace.isEmpty || action.isEmpty) {
      return {
        'ok': false,
        'status': 400,
        'error': 'core calls need namespace+action (or path "ns/action")',
      };
    }
    if (!_safeToken(namespace) || !_safeToken(action.replaceAll('/', '_'))) {
      return {'ok': false, 'status': 400, 'error': 'invalid namespace/action'};
    }
    final body = req['body'];
    final map = body is Map
        ? Map<String, dynamic>.from(body)
        : <String, dynamic>{};
    final ms = (req['timeoutMs'] as num?)?.toInt();
    final timeout = ms == null
        ? null
        : Duration(milliseconds: ms.clamp(1000, 600000).toInt());
    try {
      final resp = await service.client.call(
        namespace,
        action,
        body: map,
        requestTimeout: timeout,
      );
      return {'ok': true, 'status': resp.status, 'data': resp.body};
    } catch (e) {
      final message = '$e';
      final status = message.contains('401')
          ? 401
          : message.contains('403')
              ? 403
              : message.contains('404')
                  ? 404
                  : 500;
      return {'ok': false, 'status': status, 'error': message};
    }
  }

  Future<Map<String, dynamic>> _asemanOp(Map<String, dynamic> req) async {
    final op = '${req['op'] ?? ''}'.trim();
    // Convenience aliases used by the stock SDK when a space page is absent.
    switch (op) {
      case 'context':
        return {
          'ok': true,
          'status': 200,
          'data': {
            'user': env()['user'],
            'space': spaceId,
            'room': roomId,
            'slot': slot,
            'kind': 'theme',
          },
        };
      case 'agents':
        // Same as the page API `_decillion/api/agents` → spaces.bots_list,
        // filtered to agent members and reshaped to {agents:…}.
        return _spaceAgentsAlias(req);
      case 'tools':
        // Same as the page API `_decillion/api/tools` → spaces.tools_list.
        return _coreCall({
          ...req,
          'namespace': 'spaces',
          'action': 'tools_list',
          'body': _spaceScopedBody(req),
        });
      default:
        // Treat op as "namespace.action" or pass through body.namespace.
        if (op.contains('.')) {
          final i = op.indexOf('.');
          return _coreCall({
            ...req,
            'namespace': op.substring(0, i),
            'action': op.substring(i + 1),
          });
        }
        final body = req['body'];
        if (body is Map &&
            body['namespace'] != null &&
            body['action'] != null) {
          return _coreCall({
            ...req,
            'namespace': body['namespace'],
            'action': body['action'],
            'body': body['args'] ?? body['body'] ?? const <String, dynamic>{},
          });
        }
        return {
          'ok': false,
          'status': 400,
          'error':
              'theme panels: use target "core" with {namespace,action}, or decillion op "ns.action"',
        };
    }
  }

  /// Body for space-scoped page-API aliases; [spaceId]/[roomId] win over req.
  Map<String, dynamic> _spaceScopedBody(Map<String, dynamic> req) {
    final fromReq = req['body'] is Map
        ? Map<String, dynamic>.from(req['body'] as Map)
        : <String, dynamic>{};
    return {
      ...fromReq,
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
    };
  }

  /// Page-API `agents` shape over `spaces.bots_list` (agents only).
  Future<Map<String, dynamic>> _spaceAgentsAlias(
      Map<String, dynamic> req) async {
    final resp = await _coreCall({
      ...req,
      'namespace': 'spaces',
      'action': 'bots_list',
      'body': _spaceScopedBody(req),
    });
    if (resp['ok'] != true) return resp;
    final data = resp['data'];
    final bots = data is Map ? data['bots'] : null;
    final agents = <Map<String, dynamic>>[];
    if (bots is List) {
      for (final raw in bots) {
        if (raw is! Map) continue;
        final b = Map<String, dynamic>.from(raw);
        if ('${b['kind'] ?? ''}' != 'agent') continue;
        final id = '${b['id'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        agents.add({
          'id': id,
          'name': b['name'] ?? '',
          'description': b['description'] ?? '',
          'status': b['status'] ?? '',
        });
      }
    }
    return {
      'ok': true,
      'status': resp['status'] ?? 200,
      'data': {'agents': agents},
    };
  }

  Future<Map<String, dynamic>> _httpFetch(Map<String, dynamic> req) async {
    final rawUrl = '${req['url'] ?? req['path'] ?? ''}'.trim();
    if (rawUrl.isEmpty) {
      return {'ok': false, 'status': 400, 'error': 'http target needs url'};
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      return {
        'ok': false,
        'status': 400,
        'error': 'only http(s) urls are allowed',
      };
    }
    final method = '${req['method'] ?? 'GET'}'.toUpperCase();
    final ms = (req['timeoutMs'] as num?)?.toInt() ?? 60000;
    final timeout = Duration(milliseconds: ms.clamp(1000, 120000).toInt());
    final headers = <String, String>{
      ...service.authHeaders(),
      if (req['headers'] is Map)
        for (final e in (req['headers'] as Map).entries)
          if (!_reserved('${e.key}')) '${e.key}': '${e.value}',
    };
    try {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (req.containsKey('body') && method != 'GET') {
        final body = req['body'];
        request.body = body is String ? body : jsonEncode(body);
        request.headers.putIfAbsent('Content-Type', () => 'application/json');
      }
      final streamed = await _client.send(request).timeout(timeout);
      final res = await http.Response.fromStream(streamed).timeout(timeout);
      final text = utf8.decode(res.bodyBytes, allowMalformed: true);
      dynamic json;
      try {
        json = text.isEmpty ? null : jsonDecode(text);
      } catch (_) {
        json = null;
      }
      return {
        'ok': res.statusCode >= 200 && res.statusCode < 300,
        'status': res.statusCode,
        'data': {
          'status': res.statusCode,
          'ok': res.statusCode >= 200 && res.statusCode < 300,
          'json': json,
          'text': text.length > 1 << 20 ? text.substring(0, 1 << 20) : text,
        },
      };
    } on TimeoutException {
      return {'ok': false, 'status': 504, 'error': 'timed out'};
    }
  }

  static bool _safeToken(String s) =>
      s.isNotEmpty && RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(s);

  static bool _reserved(String name) {
    final n = name.toLowerCase();
    return n == 'authorization' || n == 'cookie' || n.startsWith('x-decillion-');
  }

  static Map<String, dynamic>? _decodeMap(String payload) {
    dynamic v = HostValues.decode(payload);
    if (v is String) v = HostValues.decode(v);
    if (v is List && v.isNotEmpty) v = v.first;
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }
}
