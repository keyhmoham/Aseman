import 'dart:async';

/// Asks the tool's server something for its app: `tools/call` or
/// `resources/read` (through the node, as the person).
typedef McpAppRpc = Future<Map<String, dynamic>> Function(
    String method, Map<String, dynamic> params);

/// The host side of an MCP App (a tool's ui:// HTML app, run in a sandboxed
/// frame): JSON-RPC over postMessage. It answers the app's handshake, hands
/// it the tool's input and result, relays its calls to its own server and
/// opens the links it asks for. [send] delivers a message to the app;
/// [receive] takes one from it.
class McpAppHost {
  McpAppHost({
    required this.send,
    required this.rpc,
    required this.arguments,
    required this.result,
    this.theme = 'light',
    this.platform = 'web',
    this.locale = 'en',
    this.openLink,
    this.onSize,
  });

  final void Function(Map<String, dynamic> message) send;
  final McpAppRpc rpc;

  /// The arguments the tool was called with (the app's tool input).
  final Map<String, dynamic> arguments;

  /// The tool's result, once there is one.
  final Future<Map<String, dynamic>> result;
  final String theme;
  final String platform;
  final String locale;
  final Future<void> Function(Uri url)? openLink;

  /// The size the app's content wants.
  final void Function(double? width, double? height)? onSize;

  bool _initialized = false;
  bool _closed = false;

  static const protocolVersion = '2025-11-21';

  Map<String, dynamic> get hostContext => {
        'theme': theme,
        'displayMode': 'inline',
        'availableDisplayModes': const ['inline'],
        'platform': platform,
        'locale': locale,
      };

  /// A message from the app.
  Future<void> receive(Object? raw) async {
    if (_closed || raw is! Map) return;
    final message = raw.cast<String, dynamic>();
    final method = message['method'];
    final Object? id = message['id'];
    final params = message['params'] is Map
        ? (message['params'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    if (method is! String) return; // a response: the host asks nothing
    if (id == null) {
      _notification(method, params);
      return;
    }
    try {
      final result = await _request(method, params);
      if (result == null) {
        _reply(id,
            error: {'code': -32601, 'message': 'Method not found: $method'});
      } else {
        _reply(id, result: result);
      }
    } catch (e) {
      _reply(id, error: {'code': -32603, 'message': '$e'});
    }
  }

  void _reply(Object id,
      {Map<String, dynamic>? result, Map<String, dynamic>? error}) {
    if (_closed) return;
    send({
      'jsonrpc': '2.0',
      'id': id,
      if (error != null) 'error': error else 'result': result ?? const {},
    });
  }

  void _notify(String method, Map<String, dynamic> params) {
    if (_closed) return;
    send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  Future<Map<String, dynamic>?> _request(
      String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'ui/initialize':
        final asked = params['protocolVersion'];
        return {
          'protocolVersion': asked is String ? asked : protocolVersion,
          'hostInfo': {'name': 'Tradera', 'version': '1.0.0'},
          'hostCapabilities': {
            'openLinks': <String, dynamic>{},
            'serverTools': <String, dynamic>{},
            'serverResources': <String, dynamic>{},
            'logging': <String, dynamic>{},
          },
          'hostContext': hostContext,
        };
      case 'tools/call':
        return rpc('tools/call', params);
      case 'resources/read':
        return rpc('resources/read', params);
      case 'ui/open-link':
        final url = Uri.tryParse('${params['url'] ?? ''}');
        if (url == null ||
            !(url.isScheme('https') ||
                url.isScheme('http') ||
                url.isScheme('mailto'))) {
          return {'isError': true};
        }
        await openLink?.call(url);
        return const {};
      case 'ui/request-display-mode':
        return {'mode': 'inline'};
      case 'ui/message':
      case 'ui/update-model-context':
      case 'ping':
        return const {};
    }
    return null;
  }

  void _notification(String method, Map<String, dynamic> params) {
    switch (method) {
      case 'ui/notifications/initialized':
        if (_initialized) return;
        _initialized = true;
        _notify('ui/notifications/tool-input', {'arguments': arguments});
        result.then((r) => _notify('ui/notifications/tool-result', r),
            onError: (Object e) => _notify('ui/notifications/tool-result', {
                  'isError': true,
                  'content': [
                    {'type': 'text', 'text': '$e'}
                  ],
                }));
      case 'ui/notifications/size-changed':
        double? n(Object? v) => v is num && v > 0 ? v.toDouble() : null;
        onSize?.call(n(params['width']), n(params['height']));
    }
  }

  /// The frame is going away: the app may save its state.
  void teardown() {
    if (_closed) return;
    send({
      'jsonrpc': '2.0',
      'id': 'teardown',
      'method': 'ui/resource-teardown',
      'params': <String, dynamic>{},
    });
    _closed = true;
  }
}
