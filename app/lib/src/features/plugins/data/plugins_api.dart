import '../../../data/services/aseman_service.dart';
import '../../tools/data/tools_api.dart';
import '../../tools/domain/tool_models.dart';

/// Where a plugin is shown.
enum PluginPlacement {
  /// Beside the conversation (a room, thread or chat).
  panel,

  /// A page of its own.
  page,

  /// A window on the room's desk.
  desk;

  static PluginPlacement parse(Object? v) => switch ('$v') {
        'page' => PluginPlacement.page,
        'desk' => PluginPlacement.desk,
        _ => PluginPlacement.panel,
      };
}

/// A plugin agents made for people (Creator mode): an Elpian screen with its
/// backend. App-wide plugins are the person's own, everywhere in the app; a
/// space's plugins belong to that space and its members.
class PluginInfo {
  const PluginInfo({
    required this.id,
    required this.name,
    this.description = '',
    this.appWide = false,
    this.spaceId = '',
    this.ownerId = '',
    this.placement = PluginPlacement.panel,
    this.permissions = const [],
    this.removed = false,
  });

  factory PluginInfo.fromJson(Map<String, dynamic> j) => PluginInfo(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        description: '${j['description'] ?? ''}',
        appWide: j['scope'] == 'account',
        spaceId: '${j['space_id'] ?? ''}',
        ownerId: '${j['owner'] ?? ''}',
        placement: PluginPlacement.parse(j['placement']),
        permissions: [
          for (final p in (j['permissions'] as List?) ?? const []) '$p'
        ],
        removed: j['status'] == 'removed',
      );

  final String id;
  final String name;
  final String description;
  final bool appWide;
  final String spaceId;
  final String ownerId;
  final PluginPlacement placement;
  final List<String> permissions;
  final bool removed;
}

/// The plugins of the tools namespace, as the signed-in person.
class PluginsApi {
  PluginsApi(this._call);

  factory PluginsApi.of(AsemanService service) => PluginsApi(
      (namespace, action, body, {timeout}) async => (await service.client
              .call(namespace, action, body: body, requestTimeout: timeout))
          .body);

  final ActionCall _call;

  Map<String, dynamic> _map(dynamic body) =>
      body is Map ? body.cast<String, dynamic>() : <String, dynamic>{};

  /// The person's app-wide plugins and, with [spaceId], that space's.
  Future<List<PluginInfo>> list(
      {String spaceId = '', bool removed = false}) async {
    final body = _map(await _call('tools', 'plugin_list', {
      if (spaceId.isNotEmpty) 'space': spaceId,
      if (removed) 'removed': true,
    }));
    return [
      for (final p in (body['plugins'] as List?) ?? const [])
        if (p is Map) PluginInfo.fromJson(p.cast<String, dynamic>()),
    ];
  }

  Future<void> remove(String plugin) =>
      _call('tools', 'plugin_remove', {'plugin': plugin});

  Future<void> restore(String plugin) =>
      _call('tools', 'plugin_restore', {'plugin': plugin});

  /// The plugin's own backend (`tool.call` of its screen).
  Future<dynamic> invoke(String plugin, String function,
      {String roomId = '', Map<String, dynamic> args = const {}}) async {
    final body = _map(await _call(
        'tools',
        'plugin_invoke',
        {
          'plugin': plugin,
          'function': function,
          'payload': args,
          if (roomId.isNotEmpty) 'room': roomId,
        },
        timeout: ToolsApi.backendTimeout));
    return microtoolValue(body['result']);
  }

  /// A platform action the plugin declared (`aseman.call` of its screen);
  /// the node allows only those, as the person using it.
  Future<dynamic> call(String plugin, String namespace, String action,
          Map<String, dynamic> body) =>
      _call('tools', 'plugin_call', {
        'plugin': plugin,
        'namespace': namespace,
        'action': action,
        'body': body,
      });
}
