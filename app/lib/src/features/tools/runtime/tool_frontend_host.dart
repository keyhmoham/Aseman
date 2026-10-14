import 'dart:async';

import '../../../elpian/elpian.dart';
import '../../miniapps/elpian/host_values.dart';
import '../data/tools_api.dart';

/// The host a tool's static frontend runs against — an Elpian miniapp on the
/// Elpian VM or QuickJS. Its program reaches its own backend, whatever the
/// backend's mode, by calling microtools:
///
///   * `tool.call(microtool, args)` → the microtool's result
///     (`server.call` is the same, for miniapp programs written against it)
///   * `tool.microtools()`         → what the backend offers
///   * `tool.context()`            → `{tool, space, room, user}`
///
/// Every call goes through the node signed as the person using the app, in
/// the space (and room) the frontend was opened in: the backend sees who is
/// asking and from where.
class ToolFrontendHost {
  ToolFrontendHost(this.api,
      {required this.botId,
      required this.spaceId,
      this.roomId = '',
      this.userId = ''});

  final ToolsApi api;
  final String botId;
  final String spaceId;
  final String roomId;
  final String userId;

  Map<String, HostCallHandler> handlers() => {
        'tool.call': _call,
        'server.call': _call,
        'host.request': _call,
        'tool.microtools': _microtools,
        'tool.context': _context,
      };

  /// `[microtool, args]` or `{microtool, args}`.
  FutureOr<String> _call(String apiName, String payload) async {
    final args = HostValues.args(payload);
    String name = '';
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
      final value = await api.invoke(botId, name,
          spaceId: spaceId, roomId: roomId, args: input);
      return HostValues.reply('object', value);
    } catch (e) {
      return HostValues.error('tool_error', e);
    }
  }

  FutureOr<String> _microtools(String apiName, String payload) async {
    try {
      final list = await api.microtools(botId, spaceId: spaceId);
      return HostValues.reply('object', [
        for (final m in list)
          {'name': m.name, 'description': m.description, 'input': m.schema},
      ]);
    } catch (e) {
      return HostValues.error('tool_error', e);
    }
  }

  FutureOr<String> _context(String apiName, String payload) => HostValues.reply(
      'object',
      {'tool': botId, 'space': spaceId, 'room': roomId, 'user': userId});
}
