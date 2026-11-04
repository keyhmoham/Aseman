import 'dart:async';

import '../../../elpian/elpian.dart';
import '../../tools/elpian/host_values.dart';
import '../data/plugins_api.dart';

/// What a plugin's screen may ask of the app, on top of what every tool
/// frontend has (rendering, `tool.compact`, `tool.expand`).
///
/// An Elpian plugin runs on the Aseman Elpian SDK and the plugin shim
/// (`assets/elpian/aseman-plugin.js`): `Aseman.plugin.call / api / get / set
/// / context` send `aseman.request` with target `plugin`, answered later
/// through [settle] (the program's `__asemanSettle`). A web plugin's bridge
/// (`aseman-web-plugin.js`) asks the same [perform] by messages. Older
/// plugins call the host directly:
///
///   * `tool.call(microtool, args)` → its own backend (through the node's
///     plugin gate, as the person using it);
///   * `aseman.call(namespace, action, body)` → a platform action it
///     declared, as the person using it; the node refuses anything else, and
///     a space's plugin stays in its space;
///   * `aseman.context()` → `{plugin, space, room, user, display, scope}`.
class PluginHost {
  PluginHost(this.api,
      {required this.plugin,
      this.spaceId = '',
      this.roomId = '',
      this.userId = '',
      this.display = 'full',
      this.settle,
      this.env});

  final PluginsApi api;
  final PluginInfo plugin;
  final String spaceId;
  final String roomId;
  final String userId;
  final String display;

  /// Delivers an answer to the program (`__asemanSettle`); without it
  /// `aseman.request` is refused.
  final Future<void> Function(Map<String, dynamic> result)? settle;

  /// The theme, display and viewport the SDK reads (`Aseman.env()`).
  final Map<String, dynamic> Function()? env;

  bool _disposed = false;

  /// Stops delivering answers (the screen is gone).
  void dispose() => _disposed = true;

  Map<String, HostCallHandler> handlers() => {
        'tool.call': _invoke,
        'server.call': _invoke,
        'host.request': _invoke,
        'aseman.call': _call,
        'aseman.context': (_, __) => HostValues.reply('object', context()),
        'aseman.request': _request,
        'aseman.env': (_, __) =>
            HostValues.reply('object', {...?env?.call(), 'kind': 'plugin'}),
      };

  /// Where the plugin is and whose it is.
  Map<String, dynamic> context() => {
        'plugin': plugin.id,
        'name': plugin.name,
        'scope': plugin.appWide ? 'account' : 'space',
        'space': plugin.appWide ? spaceId : plugin.spaceId,
        'room': roomId,
        'user': userId,
        'display': display,
      };

  /// One plugin request (`invoke`, `call` or `context`) as
  /// `{ok, data}` or `{ok: false, error}`.
  Future<Map<String, dynamic>> perform(
      String op, Map<String, dynamic> body) async {
    try {
      switch (op) {
        case 'invoke':
          final name = '${body['function'] ?? body['microtool'] ?? ''}';
          if (name.isEmpty) {
            return {'ok': false, 'error': 'say which backend function'};
          }
          final args = body['args'] is Map
              ? (body['args'] as Map).cast<String, dynamic>()
              : const <String, dynamic>{};
          return {
            'ok': true,
            'data': await api.invoke(plugin.id, name, roomId: roomId, args: args)
          };
        case 'call':
          final namespace = '${body['namespace'] ?? ''}';
          final action = '${body['action'] ?? ''}';
          if (namespace.isEmpty || action.isEmpty) {
            return {'ok': false, 'error': 'say the namespace and the action'};
          }
          final payload = body['body'] is Map
              ? (body['body'] as Map).cast<String, dynamic>()
              : const <String, dynamic>{};
          return {
            'ok': true,
            'data': await api.call(plugin.id, namespace, action, payload)
          };
        case 'context':
          return {'ok': true, 'data': context()};
        default:
          return {
            'ok': false,
            'error': 'a plugin asks invoke, call or context (got "$op")'
          };
      }
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// `{id, target: "plugin", op, body}`: accepted now, answered through
  /// [settle]. The SDK's own `Aseman.context()` is answered too; the rest
  /// of the SDK's page API is not a plugin's.
  FutureOr<String> _request(String apiName, String payload) {
    final req = _decodeMap(payload);
    final id = '${req?['id'] ?? ''}';
    final deliver = settle;
    if (req == null || id.isEmpty) {
      return HostValues.reply(
          'object', {'error': 'aseman.request needs {id, target, op}'});
    }
    if (deliver == null) {
      return HostValues.reply(
          'object', {'error': 'this screen cannot receive answers'});
    }
    final target = '${req['target'] ?? ''}';
    final op = '${req['op'] ?? ''}';
    final body = req['body'] is Map
        ? (req['body'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final Future<Map<String, dynamic>> answer;
    if (target == 'plugin') {
      answer = perform(op, body);
    } else if (target == 'aseman' && op == 'context') {
      answer = Future.value({'ok': true, 'data': context()});
    } else {
      answer = Future.value({
        'ok': false,
        'status': 404,
        'error':
            'a plugin reaches its backend and the platform with Aseman.plugin.call / api (not $target ${op.isEmpty ? req['path'] ?? '' : op})',
      });
    }
    unawaited(answer.then((result) async {
      if (_disposed) return;
      await deliver({'id': id, 'status': result['ok'] == true ? 200 : 400, ...result});
    }));
    return HostValues.reply('object', {'accepted': true});
  }

  FutureOr<String> _invoke(String apiName, String payload) async {
    final args = HostValues.args(payload);
    var name = '';
    Map<String, dynamic> input = const {};
    if (args.isNotEmpty && args.first is Map) {
      final m = (args.first as Map).cast<String, dynamic>();
      name = '${m['microtool'] ?? m['name'] ?? ''}';
      input = (m['args'] as Map?)?.cast<String, dynamic>() ?? const {};
    } else {
      name = args.isNotEmpty ? '${args.first}' : '';
      if (args.length > 1 && args[1] is Map) {
        input = (args[1] as Map).cast<String, dynamic>();
      }
    }
    if (name.isEmpty) {
      return HostValues.error('invalid_argument', 'microtool name required');
    }
    try {
      return HostValues.reply('object',
          await api.invoke(plugin.id, name, roomId: roomId, args: input));
    } catch (e) {
      return HostValues.error('tool_error', e);
    }
  }

  /// `[namespace, action, body]` or `{namespace, action, body}`.
  FutureOr<String> _call(String apiName, String payload) async {
    final args = HostValues.args(payload);
    var namespace = '', action = '';
    Map<String, dynamic> body = const {};
    if (args.isNotEmpty && args.first is Map) {
      final m = (args.first as Map).cast<String, dynamic>();
      namespace = '${m['namespace'] ?? ''}';
      action = '${m['action'] ?? ''}';
      body = (m['body'] as Map?)?.cast<String, dynamic>() ?? const {};
    } else if (args.length >= 2) {
      namespace = '${args[0]}';
      action = '${args[1]}';
      if (args.length > 2 && args[2] is Map) {
        body = (args[2] as Map).cast<String, dynamic>();
      }
    }
    if (namespace.isEmpty || action.isEmpty) {
      return HostValues.error(
          'invalid_argument', 'aseman.call takes namespace, action and body');
    }
    try {
      return HostValues.reply(
          'object', await api.call(plugin.id, namespace, action, body));
    } catch (e) {
      return HostValues.error('platform_error', e);
    }
  }

  static Map<String, dynamic>? _decodeMap(String payload) {
    dynamic v = HostValues.decode(payload);
    if (v is String) v = HostValues.decode(v);
    if (v is List && v.isNotEmpty) v = v.first;
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }
}
