import '../../../data/services/aseman_service.dart';
import '../../tools/data/tools_api.dart';

/// Preferred size / start hint for a space gadget floater. Space gadgets
/// share one layer over the whole workspace (left panel, chat and desk);
/// account gadgets are universal floaters across every home tab and
/// workspaces. Only [page] opens as its own route instead of floating.
enum GadgetPlacement {
  /// Size hint: conversation-scale floater.
  chat,

  /// Size hint: narrower floater (was the left rail).
  rail,

  /// A page of its own (not a shared floater).
  page,

  /// Size hint: desk-scale floater.
  desk;

  static GadgetPlacement parse(Object? v) => switch ('$v') {
        'page' => GadgetPlacement.page,
        'desk' => GadgetPlacement.desk,
        'rail' => GadgetPlacement.rail,
        'chat' => GadgetPlacement.chat,
        _ => GadgetPlacement.chat,
      };

  String get wire => name;
}

/// A gadget: an App UI (Elpian or web) hosted as a frameless free-position
/// gadget. App-wide gadgets are the person's own universal gadgets; a space's
/// gadgets belong to that space and its members.
class GadgetInfo {
  const GadgetInfo({
    required this.id,
    required this.name,
    this.description = '',
    this.appWide = false,
    this.spaceId = '',
    this.ownerId = '',
    this.placement = GadgetPlacement.chat,
    this.removed = false,
    this.web = false,
    this.preview = '',
    this.entry = '',
    this.appId = '',
  });

  factory GadgetInfo.fromJson(Map<String, dynamic> j) => GadgetInfo(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        description: '${j['description'] ?? ''}',
        appWide: j['scope'] == 'account',
        spaceId: '${j['space_id'] ?? ''}',
        ownerId: '${j['owner'] ?? ''}',
        placement: GadgetPlacement.parse(j['placement']),
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
  final GadgetPlacement placement;
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

/// The gadgets of the tools namespace, as the signed-in person.
class GadgetsApi {
  GadgetsApi(this._call);

  factory GadgetsApi.of(AsemanService service) => GadgetsApi(
      (namespace, action, body, {timeout}) async => (await service.client
              .call(namespace, action, body: body, requestTimeout: timeout))
          .body);

  final ActionCall _call;

  Map<String, dynamic> _map(dynamic body) =>
      body is Map ? body.cast<String, dynamic>() : <String, dynamic>{};

  /// The person's app-wide gadgets and, with [spaceId], that space's.
  Future<List<GadgetInfo>> list({String spaceId = ''}) async {
    final body = _map(await _call('tools', 'gadget_list', {
      if (spaceId.isNotEmpty) 'space': spaceId,
    }));
    return [
      for (final p in (body['gadgets'] as List?) ?? const [])
        if (p is Map) GadgetInfo.fromJson(p.cast<String, dynamic>()),
    ];
  }

  Future<void> remove(String gadget) =>
      _call('tools', 'gadget_remove', {'gadget': gadget});
}
