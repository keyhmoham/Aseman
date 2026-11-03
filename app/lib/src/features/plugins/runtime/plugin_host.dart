import 'dart:async';

import '../../../elpian/elpian.dart';
import '../../tools/elpian/host_values.dart';
import '../data/plugins_api.dart';

/// What a plugin's screen may ask of the app, on top of what every tool
/// frontend has (rendering, `tool.compact`, `tool.expand`):
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
      this.display = 'full'});

  final PluginsApi api;
  final PluginInfo plugin;
  final String spaceId;
  final String roomId;
  final String userId;
  final String display;

  Map<String, HostCallHandler> handlers() => {
        'tool.call': _invoke,
        'server.call': _invoke,
        'host.request': _invoke,
        'aseman.call': _call,
        'aseman.context': _context,
      };

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

  FutureOr<String> _context(String apiName, String payload) =>
      HostValues.reply('object', {
        'plugin': plugin.id,
        'name': plugin.name,
        'scope': plugin.appWide ? 'account' : 'space',
        'space': plugin.appWide ? spaceId : plugin.spaceId,
        'room': roomId,
        'user': userId,
        'display': display,
      });
}
