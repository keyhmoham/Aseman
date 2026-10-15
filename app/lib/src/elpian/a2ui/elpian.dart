/// A2UI inside Elpian, rendered by genui with Tradera's catalog: the
/// `A2UISurface` widget (also `a2ui-surface`), the
/// per-app conversation registry it and the host APIs share, and the guest
/// host APIs `agent.send`, `agent.action` and `a2ui.dataModel`.
///
/// Widget props:
///   agent         agent name (`/apps/<app>/agent/<agent>`)
///   app           app id (default: the registry's — the current app)
///   baseUrl       server base URL (default: the registry's)
///   conversation  conversation key; widgets with the same key share one
///                 conversation (default `agent:<agent>`)
///   prompt        first message, sent once when the conversation is new
///   surfaceId     render only this surface (default: all, in creation order)
///   showText      render the agent's prose
///   chat          add an input row to message the agent
///   messages      static A2UI messages to render without an agent
/// Events (dispatched to the node's `events` handlers — closures, or VM
/// function names routed like any other event):
///   a2uiAction  {name, surfaceId, sourceComponentId, timestamp, context}
///   a2uiText    {text}
///   a2uiError   {message}
///   a2uiDone    {stopReason, conversationId}
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../genui/runtime/host.dart';
import '../../genui/widgets/surface_view.dart';
import '../core/elpian_services.dart';
import '../core/event_system.dart';
import '../models/elpian_node.dart';
import 'conversation.dart';
import 'transport.dart';

/// The guest host APIs this module serves.
const Set<String> agentApiNames = {
  'agent.send',
  'agent.action',
  'a2ui.dataModel'
};

/// Where agents are reached when a widget or host call does not say.
class A2UIDefaults {
  const A2UIDefaults({this.baseUrl, this.appId, this.headers = const {}});
  final String? baseUrl;
  final String? appId;
  final Map<String, String> headers;
}

/// Conversations of one app (one [ElpianServices]), keyed by conversation
/// key. Listeners (the rendered `A2UISurface` widgets) are told to rebuild
/// whenever any conversation changes.
class A2UIRegistry extends ChangeNotifier {
  A2UIDefaults defaults = const A2UIDefaults();

  /// The transport new conversations use (tests and custom hosts replace it).
  AgentFetchStream fetch = httpFetchStream;

  final Map<String, A2UIConversation> _conversations = {};
  bool _disposed = false;

  /// The conversation under [key], created by [create] when new.
  A2UIConversation conversation(
      String key, A2UIConversation Function() create) {
    var c = _conversations[key];
    if (c == null) {
      c = create();
      _conversations[key] = c;
      c.on((e) {
        if (e.type == 'changed') invalidate();
      });
    }
    return c;
  }

  A2UIConversation? operator [](String key) => _conversations[key];

  List<String> get keys => _conversations.keys.toList();

  /// An endpoint for [agent] from the defaults (and overrides), or null
  /// without an agent, a base URL or an app id.
  AgentEndpoint? endpoint(String agent, {Object? baseUrl, Object? appId}) {
    final base =
        baseUrl is String && baseUrl.isNotEmpty ? baseUrl : defaults.baseUrl;
    final app = appId is String && appId.isNotEmpty ? appId : defaults.appId;
    if (agent.isEmpty || base == null || app == null || app.isEmpty) {
      return null;
    }
    return AgentEndpoint(
        baseUrl: base, appId: app, agent: agent, headers: defaults.headers);
  }

  /// A new conversation with this registry's transport.
  A2UIConversation create({AgentEndpoint? endpoint, String? conversationId}) =>
      A2UIConversation(
          endpoint: endpoint, conversationId: conversationId, fetch: fetch);

  /// Every rendered surface builds again.
  void invalidate() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _conversations.values) {
      c.dispose();
    }
    _conversations.clear();
    super.dispose();
  }
}

final Expando<A2UIRegistry> _registries = Expando('a2ui');

/// The A2UI registry of an app's services (created on first use).
A2UIRegistry a2uiRegistry(ElpianServices services) =>
    _registries[services] ??= A2UIRegistry();

String _conversationKey(Map<String, dynamic> props, String elementId) {
  final c = props['conversation'];
  if (c is String && c.isNotEmpty) return c;
  if (props['messages'] is List) return 'static:$elementId';
  return 'agent:${props['agent'] is String ? props['agent'] : ''}';
}

/// The conversation an `A2UISurface` element with [props] shows (created on
/// first use, endpoint resolved from the registry defaults).
A2UIConversation a2uiConversationFor(
    A2UIRegistry registry, Map<String, dynamic> props, String elementId) {
  final agent = props['agent'] is String ? props['agent'] as String : '';
  final isStatic = props['messages'] is List;
  final conversation = registry.conversation(
    _conversationKey(props, elementId),
    () => registry.create(
      endpoint: isStatic
          ? null
          : registry.endpoint(agent,
              baseUrl: props['baseUrl'], appId: props['app']),
      conversationId: props['conversationId'] is String
          ? props['conversationId'] as String
          : null,
    ),
  );
  if (conversation.endpoint == null && agent.isNotEmpty && !isStatic) {
    conversation.endpoint = registry.endpoint(agent,
        baseUrl: props['baseUrl'], appId: props['app']);
  }
  if (isStatic) {
    final messages = props['messages'] as List;
    conversation.syncStatic(messages, jsonEncode(messages));
  }
  return conversation;
}

/// The engine builder for `A2UISurface` / `a2ui-surface`.
Widget buildA2UISurface(ElpianNode node, List<Widget> children) {
  final services = ElpianServices.current;
  return A2UISurfaceView(
    node: node,
    services: services,
    key: node.key == null ? null : ValueKey('a2ui:${node.key}'),
  );
}

/// The widget behind an `A2UISurface` node: renders the surfaces of its
/// conversation with genui (Tradera's catalog), rebuilds when the
/// conversation changes, and delivers conversation events to the node's
/// `events`.
class A2UISurfaceView extends StatefulWidget {
  const A2UISurfaceView(
      {super.key, required this.node, required this.services});

  final ElpianNode node;
  final ElpianServices services;

  @override
  State<A2UISurfaceView> createState() => _A2UISurfaceViewState();
}

class _A2UISurfaceViewState extends State<A2UISurfaceView> {
  late A2UIRegistry _registry;
  A2UIConversation? _conversation;
  VoidCallback? _unsubscribe;
  bool _building = false;
  bool _scheduled = false;

  /// Stable across rebuilds (a node without a key gets one per widget state).
  late final String _fallbackId = 'a2ui_${identityHashCode(this)}';

  String get _elementId => widget.node.key ?? _fallbackId;

  @override
  void initState() {
    super.initState();
    _registry = a2uiRegistry(widget.services)..addListener(_changed);
  }

  @override
  void didUpdateWidget(A2UISurfaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.services != widget.services) {
      _registry.removeListener(_changed);
      _registry = a2uiRegistry(widget.services)..addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted || _building) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_scheduled) return;
      _scheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  void _bind(A2UIConversation conversation) {
    if (identical(conversation, _conversation)) return;
    _unsubscribe?.call();
    _conversation = conversation;
    _unsubscribe = conversation.on(_deliver);
  }

  void _deliver(A2UIConversationEvent e) {
    String type;
    Map<String, dynamic> payload;
    switch (e.type) {
      case 'action':
        type = 'a2uiAction';
        payload = e.action!.toJson();
      case 'text':
        if (e.role != 'agent') return;
        type = 'a2uiText';
        payload = {'text': e.text};
      case 'error':
        type = 'a2uiError';
        payload = {'message': e.message};
      case 'done':
        type = 'a2uiDone';
        payload = {
          'stopReason': e.stopReason,
          'conversationId': e.conversationId
        };
      default:
        return;
    }
    final events = widget.node.events ?? const {};
    final name = events.keys.firstWhere(
        (k) => k.toLowerCase() == type.toLowerCase(),
        orElse: () => '');
    if (name.isEmpty) return;
    final dispatcher = widget.services.events;
    final id = widget.node.key ?? 'element_${widget.node.hashCode}';
    final event = ElpianEvent(
        type: name,
        eventType: ElpianEventType.custom,
        target: id,
        data: {...payload, 'value': payload});
    if (dispatcher.getNode(id) != null) {
      dispatcher.dispatchEvent(event, id);
    } else {
      // Not registered (no gesture wrapper yet): call a closure directly.
      final handler = events[name];
      if (handler is void Function(ElpianEvent)) handler(event);
    }
  }

  @override
  void dispose() {
    _registry.removeListener(_changed);
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _building = true;
    try {
      final props = widget.node.props;
      final conversation = a2uiConversationFor(_registry, props, _elementId);
      _bind(conversation);
      final prompt = props['prompt'];
      if (prompt is String &&
          prompt.isNotEmpty &&
          !conversation.prompted &&
          conversation.endpoint != null) {
        conversation.prompted = true;
        // Not during a build: the turn emits events.
        scheduleMicrotask(() => conversation.send(prompt));
      }
      final only = props['surfaceId'];
      final surfaces = [
        for (final id in conversation.surfaces.surfaceIds)
          if (only is! String || only.isEmpty || id == only) id
      ];
      Widget result = GenUiHost(
        elpianServices: widget.services,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            for (final id in surfaces)
              GenUiSurfaceView(
                key: ValueKey('$_elementId/$id'),
                surfaces: conversation.surfaces,
                surfaceId: id,
                onAction: conversation.reportAction,
                showAttribution: props['showAttribution'] != false,
              ),
            if (props['showText'] == true)
              for (final t in conversation.transcript) _Bubble(entry: t),
            if (conversation.busy) const LinearProgressIndicator(minHeight: 2),
            if (props['chat'] == true)
              _ChatRow(
                key: ValueKey('$_elementId/chat'),
                conversation: conversation,
              ),
          ],
        ),
      );
      final style = props['style'];
      if (style is Map && style['padding'] != null) {
        final p = style['padding'];
        if (p is num) {
          result =
              Padding(padding: EdgeInsets.all(p.toDouble()), child: result);
        }
      }
      return Material(type: MaterialType.transparency, child: result);
    } finally {
      _building = false;
    }
  }
}

/// One transcript entry: the person's on the right, the agent's on the left.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.entry});
  final A2UITranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = entry.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(entry.text,
            style: TextStyle(
                fontSize: 15,
                height: 1.45,
                color: mine ? scheme.onPrimaryContainer : scheme.onSurface)),
      ),
    );
  }
}

/// The input row for messaging the agent.
class _ChatRow extends StatefulWidget {
  const _ChatRow({super.key, required this.conversation});
  final A2UIConversation conversation;

  @override
  State<_ChatRow> createState() => _ChatRowState();
}

class _ChatRowState extends State<_ChatRow> {
  late final _controller =
      TextEditingController(text: widget.conversation.draft);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final conversation = widget.conversation;
    final text = _controller.text.trim();
    if (text.isEmpty || conversation.endpoint == null) return;
    _controller.clear();
    conversation.draft = '';
    conversation.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.conversation.busy;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.send,
            decoration: const InputDecoration(hintText: 'Message the agent'),
            onChanged: (v) => widget.conversation.draft = v,
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: 'Send',
          onPressed: busy ? null : _submit,
          icon: const Icon(Icons.send_rounded),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------------------------------
// Host APIs
// ----------------------------------------------------------------------------

String _response(String type, Object? value) => jsonEncode({
      'type': type,
      'data': {'value': value},
    });

String _nullResponse() => _response('null', null);

String _errorResponse(String message) => _response('object', {
      'error': {'message': message}
    });

/// A typed host response for a JSON value.
String valueResponse(Object? value) {
  if (value == null) return _nullResponse();
  if (value is List) return _response('array', value);
  if (value is Map) return _response('object', value);
  if (value is String) return _response('string', value);
  if (value is bool) return _response('bool', value);
  if (value is int) return _response('i64', value);
  if (value is num) {
    return value == value.truncateToDouble() && value.abs() < 9007199254740992
        ? _response('i64', value.toInt())
        : _response('f64', value);
  }
  return _nullResponse();
}

/// The arguments of a host call: a bare object, or the guest SDK's
/// `askHost(name, [{...}])` — an args array whose first element is the object.
Map<String, dynamic> agentCallArgs(String payload) {
  Object? parsed;
  try {
    parsed = payload.isEmpty ? null : jsonDecode(payload);
  } catch (_) {
    return {};
  }
  if (parsed is List) parsed = parsed.isEmpty ? null : parsed.first;
  // A JSON-encoded object passed as a string argument.
  if (parsed is String) {
    try {
      parsed = jsonDecode(parsed);
    } catch (_) {
      return {};
    }
  }
  return parsed is Map ? Map<String, dynamic>.from(parsed) : {};
}

/// `agent.send {agent, conversation?, message}` → `{conversationId, conversation}`
/// (once the agent named the conversation); `agent.action {agent,
/// conversation?, action}` → the same; `a2ui.dataModel {conversation?, agent?,
/// surfaceId}` → the surface's current data model. `conversation` is the
/// conversation key the widgets use (default `agent:<agent>`), so guest code
/// and `A2UISurface` widgets share conversations.
Future<String> handleAgentHostCall(
    ElpianServices services, String apiName, String payload) async {
  try {
    final args = agentCallArgs(payload);
    final registry = a2uiRegistry(services);
    final agent = args['agent'] is String ? args['agent'] as String : '';
    final key = args['conversation'] is String &&
            (args['conversation'] as String).isNotEmpty
        ? args['conversation'] as String
        : 'agent:$agent';
    switch (apiName) {
      case 'agent.send':
      case 'agent.action':
        if (agent.isEmpty && registry[key] == null) {
          return _errorResponse('$apiName requires "agent"');
        }
        final conversation = registry.conversation(
            key, () => registry.create(endpoint: registry.endpoint(agent)));
        if (conversation.endpoint == null && agent.isNotEmpty) {
          conversation.endpoint = registry.endpoint(agent);
        }
        if (conversation.endpoint == null) {
          return _errorResponse('no agent endpoint is configured for this app');
        }
        A2UITurn turn;
        if (apiName == 'agent.send') {
          final message = args['message'];
          turn = conversation
              .send(message is String ? message : jsonEncode(message ?? ''));
        } else {
          final raw = args['action'];
          if (raw is! Map || raw['name'] is! String) {
            return _errorResponse(
                'agent.action requires an "action" with a "name"');
          }
          final action = Map<String, dynamic>.from(raw);
          if (action['timestamp'] is! String) {
            action['timestamp'] = DateTime.now().toUtc().toIso8601String();
          }
          if (action['context'] is! Map) {
            action['context'] = <String, dynamic>{};
          }
          turn = conversation.sendAction(action);
        }
        final conversationId = await turn.conversationId;
        registry.invalidate();
        return _response(
            'object', {'conversationId': conversationId, 'conversation': key});
      case 'a2ui.dataModel':
        final conversation = registry[key];
        final surfaceId =
            args['surfaceId'] is String ? args['surfaceId'] as String : '';
        if (conversation == null || surfaceId.isEmpty) return _nullResponse();
        return valueResponse(conversation.dataModel(surfaceId));
    }
    return _nullResponse();
  } catch (e) {
    return _errorResponse('$e');
  }
}
