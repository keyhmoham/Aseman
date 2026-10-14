import '../../../data/services/tradera_service.dart';
import '../domain/tool_models.dart';

/// Runs one node action and returns its decoded JSON body.
typedef ActionCall = Future<dynamic> Function(
    String namespace, String action, Map<String, dynamic> body,
    {Duration? timeout});

/// The tools namespace: creating tools, calling their microtools and
/// fetching their frontends. Every call is signed as the person using the
/// app, so a backend always knows who is asking.
class ToolsApi {
  ToolsApi(this._call);

  factory ToolsApi.of(TraderaService service) => ToolsApi(
      (namespace, action, body, {timeout}) async => (await service.client
              .call(namespace, action, body: body, requestTimeout: timeout))
          .body);

  final ActionCall _call;

  /// A generated frontend may be produced by a model on first use.
  static const generationTimeout = Duration(minutes: 4);

  Map<String, dynamic> _map(dynamic body) =>
      body is Map ? body.cast<String, dynamic>() : <String, dynamic>{};

  Future<ToolInfo> create(ToolDraft draft) async =>
      ToolInfo.fromJson(_map(await _call('tools', 'tool_create', draft.toJson(),
          timeout: const Duration(minutes: 2))));

  Future<ToolInfo> get(String botId) async =>
      ToolInfo.fromJson(_map(await _call('tools', 'tool_get', {'bot': botId})));

  /// Replaces the backend program and/or the frontend.
  Future<ToolInfo> update(String botId,
          {String? source, FrontendDraft? frontend}) async =>
      ToolInfo.fromJson(_map(await _call('tools', 'tool_update', {
        'bot': botId,
        if (source != null) 'source': source,
        if (frontend != null) 'frontend': frontend.toJson(),
      })));

  Future<void> delete(String botId) =>
      _call('tools', 'tool_delete', {'bot': botId});

  /// What the tool's backend offers, asked live.
  Future<List<Microtool>> microtools(String botId,
      {String spaceId = ''}) async {
    final body = _map(await _call('tools', 'tool_microtools',
        {'bot': botId, if (spaceId.isNotEmpty) 'space': spaceId}));
    return [
      for (final c in (body['commands'] as List?) ?? const <dynamic>[])
        if (c is Map) Microtool.fromJson(c.cast<String, dynamic>()),
    ];
  }

  /// Calls one microtool as the signed-in person, in a space (and room).
  /// Returns what it returned, as data.
  Future<dynamic> invoke(String botId, String microtool,
      {required String spaceId,
      String roomId = '',
      Map<String, dynamic> args = const {}}) async {
    final body = _map(await _call('tools', 'invoke', {
      'bot': botId,
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
      'function': microtool,
      'payload': args,
    }));
    return microtoolValue(body['result']);
  }

  /// The tool's frontend: its static program, or its generated surface
  /// filled with the caller's data.
  Future<ToolFrontendPayload> frontend(String botId,
      {required String spaceId,
      String roomId = '',
      bool regenerate = false,
      ShownResult? shown,
      Map<String, dynamic>? template}) async {
    final body = _map(await _call(
        'tools',
        'frontend_get',
        {
          'bot': botId,
          'space': spaceId,
          if (roomId.isNotEmpty) 'room': roomId,
          if (regenerate) 'regenerate': true,
          if (template != null) 'template': template,
          ...?shown?.toJson(),
        },
        timeout: generationTimeout));
    return ToolFrontendPayload.fromJson(body);
  }

  /// Runs an action of a generated frontend; returns the updated data model.
  Future<Map<String, dynamic>> frontendAction(String botId, String action,
      {required String spaceId,
      String roomId = '',
      Map<String, dynamic> context = const {},
      Map<String, dynamic> data = const {},
      ShownResult? shown,
      Map<String, dynamic>? template}) async {
    final body = _map(await _call('tools', 'frontend_action', {
      'bot': botId,
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
      'action': action,
      'context': context,
      'data': data,
      if (template != null) 'template': template,
      ...?shown?.toJson(),
    }));
    return (body['data'] as Map?)?.cast<String, dynamic>() ?? const {};
  }
}
