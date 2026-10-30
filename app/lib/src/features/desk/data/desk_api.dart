import 'dart:ui';

import '../../../data/services/aseman_service.dart';
import '../../tools/data/tools_api.dart' show ActionCall;
import '../domain/desk_models.dart';

/// A room's desk on the node (spaces.desktop_get / desktop_update). [room]
/// is a room id, or `home` for the space's own desk.
class DeskApi {
  DeskApi(this._call);

  factory DeskApi.of(AsemanService service) => DeskApi(
      (namespace, action, body, {timeout}) async => (await service.client
              .call(namespace, action, body: body, requestTimeout: timeout))
          .body);

  final ActionCall _call;

  Map<String, dynamic> _map(dynamic body) =>
      body is Map ? body.cast<String, dynamic>() : <String, dynamic>{};

  Future<DeskState> get(String spaceId, String room, {Duration? timeout}) async {
    final body = _map(await _call(
        'spaces', 'desktop_get', {'space': spaceId, 'room': room},
        timeout: timeout));
    return DeskState.fromJson(_map(body['desktop']));
  }

  /// Applies [ops] together; returns the desk and the id each op produced.
  Future<(DeskState, List<String>)> update(
      String spaceId, String room, List<Map<String, dynamic>> ops) async {
    final body = _map(await _call('spaces', 'desktop_update',
        {'space': spaceId, 'room': room, 'ops': ops}));
    return (
      DeskState.fromJson(_map(body['desktop'])),
      [for (final id in (body['ids'] as List?) ?? const []) '$id'],
    );
  }
}

/// The ops of [DeskApi.update].
abstract final class DeskOps {
  static Map<String, dynamic> open(String tool,
          {String kind = '',
          String title = '',
          String microtool = '',
          Map<String, dynamic> args = const {},
          Rect? rect,
          Size? size,
          DeskCompact? compact}) =>
      {
        'op': 'open',
        'tool': tool,
        if (kind.isNotEmpty) 'kind': kind,
        if (title.isNotEmpty) 'title': title,
        if (microtool.isNotEmpty) 'microtool': microtool,
        if (args.isNotEmpty) 'args': args,
        if (rect != null) ...{'x': rect.left, 'y': rect.top},
        if ((rect?.size ?? size) != null) ...{
          'w': (rect?.size ?? size)!.width,
          'h': (rect?.size ?? size)!.height,
        },
        if (compact != null && !compact.isEmpty) 'compact': compact.toJson(),
      };

  /// Places window [id] on the phone board: at index [order] among its
  /// widgets, with [shape] and [size] when given.
  static Map<String, dynamic> arrange(String id,
          {required int order, String? shape, String? size}) =>
      {
        'op': 'arrange',
        'id': id,
        'compact': {
          'order': order,
          if (shape != null && shape.isNotEmpty) 'shape': shape,
          if (size != null && size.isNotEmpty) 'size': size,
        },
      };

  static Map<String, dynamic> move(String id, Rect r) => {
        'op': 'move',
        'id': id,
        'x': r.left,
        'y': r.top,
        'w': r.width,
        'h': r.height
      };

  static Map<String, dynamic> focus(String id) => {'op': 'focus', 'id': id};
  static Map<String, dynamic> close(String id) => {'op': 'close', 'id': id};
  static Map<String, dynamic> closeTool(String tool) =>
      {'op': 'close_tool', 'tool': tool};
  static Map<String, dynamic> pin(String id) => {'op': 'pin', 'id': id};
  static Map<String, dynamic> unpin(String id) => {'op': 'unpin', 'id': id};
  static Map<String, dynamic> viewport(Size s) =>
      {'op': 'viewport', 'w': s.width, 'h': s.height};
}
