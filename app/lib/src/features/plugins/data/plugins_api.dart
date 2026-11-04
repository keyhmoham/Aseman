import '../../../data/services/aseman_service.dart';
import '../../tools/data/tools_api.dart';

/// Where a space plugin mounts as a floating gadget (account plugins are
/// always universal floaters across home and workspaces).
enum PluginPlacement {
  /// Floating gadget on the conversation (room, thread or chat).
  chat,

  /// Floating gadget on the space's left panel / nav drawer.
  rail,

  /// A page of its own.
  page,

  /// A floating gadget on the room's desk.
  desk;

  static PluginPlacement parse(Object? v) => switch ('$v') {
        'page' => PluginPlacement.page,
        'desk' => PluginPlacement.desk,
        'rail' => PluginPlacement.rail,
        'chat' => PluginPlacement.chat,
        _ => PluginPlacement.chat,
      };

  String get wire => name;
}

/// A plugin: an App UI (Elpian or web) hosted as a frameless free-position
/// gadget. App-wide plugins are the person's own universal gadgets; a space's
/// plugins belong to that space and its members.
class PluginInfo {
  const PluginInfo({
    required this.id,
    required this.name,
    this.description = '',
    this.appWide = false,
    this.spaceId = '',
    this.ownerId = '',
    this.placement = PluginPlacement.chat,
    this.removed = false,
    this.web = false,
    this.preview = '',
    this.entry = '',
    this.appId = '',
  });

  factory PluginInfo.fromJson(Map<String, dynamic> j) => PluginInfo(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        description: '${j['description'] ?? ''}',
        appWide: j['scope'] == 'account',
        spaceId: '${j['space_id'] ?? ''}',
        ownerId: '${j['owner'] ?? ''}',
        placement: PluginPlacement.parse(j['placement']),
        removed: j['status'] == 'removed',
        web: j['ui'] == 'web',
        preview: '${j['preview'] ?? ''}',
        entry: '${j['entry'] ?? ''}',
        appId: '${j['app_id'] ?? ''}',
      );

  final String id;
  final String name;
  final String description;
  final bool appWide;
  final String spaceId;
  final String ownerId;
  final PluginPlacement placement;
  final bool removed;

  /// Its screen is a web App UI rather than native Elpian.
  final bool web;

  /// Preview gateway path of the App UI (`/v1/proxy/<id>/`).
  final String preview;

  /// Elpian program path the preview serves (e.g. `elpian/app.js`). Empty for
  /// a web App UI (the preview page itself is shown).
  final String entry;

  /// App UI project id (from `appui_create`).
  final String appId;

  bool get isApp => preview.isNotEmpty;
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
}
