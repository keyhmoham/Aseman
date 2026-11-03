import '../../../data/services/aseman_service.dart';
import '../domain/tool_models.dart';

/// Runs one node action and returns its decoded JSON body.
typedef ActionCall = Future<dynamic> Function(
    String namespace, String action, Map<String, dynamic> body,
    {Duration? timeout});

/// The tools namespace: creating tools, calling their microtools and
/// fetching their frontends. Every call is signed as the person using the
/// app, so a backend always knows who is asking.
class ToolsApi {
  ToolsApi(this._call, {this.service});

  factory ToolsApi.of(AsemanService service) => ToolsApi(
      (namespace, action, body, {timeout}) async => (await service.client
              .call(namespace, action, body: body, requestTimeout: timeout))
          .body,
      service: service);

  /// The node connection behind it, when there is one: frontends load the
  /// space's files and the node's media through it.
  final AsemanService? service;

  final ActionCall _call;

  /// The node actions it runs, for APIs built on the same connection.
  ActionCall get call => _call;

  /// A generated frontend may be produced by a model on first use.
  static const generationTimeout = Duration(minutes: 4);

  /// A tool installed on the space's computer may have to wait for the
  /// computer to wake and the tool to start before it answers.
  static const backendTimeout = Duration(minutes: 4);

  Map<String, dynamic> _map(dynamic body) =>
      body is Map ? body.cast<String, dynamic>() : <String, dynamic>{};

  Future<ToolInfo> create(ToolDraft draft) async =>
      ToolInfo.fromJson(_map(await _call('tools', 'tool_create', draft.toJson(),
          timeout: const Duration(minutes: 2))));

  Future<ToolInfo> get(String botId) async =>
      ToolInfo.fromJson(_map(await _call('tools', 'tool_get', {'bot': botId})));

  /// Replaces the backend program and/or the frontend.
  Future<ToolInfo> update(String botId,
          {String? source, FrontendDraft? frontend}) =>
      edit(botId, ToolEdit(source: source, frontend: frontend));

  /// Changes what the tool form changed: its name and description, how an
  /// external backend is reached, its backend program and its frontend.
  Future<ToolInfo> edit(String botId, ToolEdit changes) async =>
      ToolInfo.fromJson(_map(await _call(
          'tools', 'tool_update', {'bot': botId, ...changes.toJson()},
          timeout: const Duration(minutes: 2))));

  Future<void> delete(String botId) =>
      _call('tools', 'tool_delete', {'bot': botId});

  /// What the tool's backend offers, asked live.
  Future<List<Microtool>> microtools(String botId,
      {String spaceId = ''}) async {
    final body = _map(await _call('tools', 'tool_microtools',
        {'bot': botId, if (spaceId.isNotEmpty) 'space': spaceId},
        timeout: backendTimeout));
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
    }, timeout: backendTimeout));
    return microtoolValue(body['result']);
  }

  /// The tool's frontend: its static program, when it has one.
  Future<ToolFrontendPayload> frontend(String botId,
      {required String spaceId,
      String roomId = '',
      ShownResult? shown}) async {
    final body = _map(await _call(
        'tools',
        'frontend_get',
        {
          'bot': botId,
          'space': spaceId,
          if (roomId.isNotEmpty) 'room': roomId,
          ...?shown?.toJson(),
        },
        timeout: generationTimeout));
    return ToolFrontendPayload.fromJson(body);
  }

  /// A request of a tool's app (MCP Apps) to its server, through the node
  /// as this person: `tools/call`, `resources/read`, or `app` (the app a
  /// microtool's results are shown with: `{uri, resource}`).
  Future<Map<String, dynamic>> appRpc(String botId, String method,
          {required String spaceId,
          String roomId = '',
          Map<String, dynamic> params = const {}}) async =>
      _map(await _call(
          'tools',
          'app_rpc',
          {
            'bot': botId,
            'space': spaceId,
            if (roomId.isNotEmpty) 'room': roomId,
            'method': method,
            'params': params,
          },
          timeout: backendTimeout));
}
