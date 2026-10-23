/// `AgUiConversation` — one conversation with one agent: AG-UI surfaces
/// ([AgUiSurfaces], over Aseman's catalog), the transcript of prose and
/// the agent transport. Turns ([AgUiConversation.send],
/// [AgUiConversation.sendAction]) run one at a time; each carries the
/// conversation id, the `sendDataModel` surfaces' data models and the
/// client's supported catalogs. Without an endpoint a conversation renders
/// static AG-UI messages ([AgUiConversation.ingest]) and actions are only
/// reported to listeners.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../agui/runtime/surfaces.dart';
import '../../agui/widgets/surface_view.dart' show AgUiAction;
import 'transport.dart';

/// `conversation`, `text` ([role] `agent` / `user`), `status`, `error`,
/// `done`, `action`, or `changed` (surfaces, transcript or busy state
/// changed: render again).
class AgUiConversationEvent {
  AgUiConversationEvent(this.type,
      {this.conversationId,
      this.text,
      this.role,
      this.state,
      this.tool,
      this.message,
      this.stopReason,
      this.action});

  final String type;
  final String? conversationId;
  final String? text;
  final String? role;
  final String? state;
  final String? tool;
  final String? message;
  final String? stopReason;
  final AgUiAction? action;
}

typedef AgUiConversationListener = void Function(AgUiConversationEvent event);

class AgUiTranscriptEntry {
  const AgUiTranscriptEntry(this.role, this.text);
  final String role;
  final String text;
  Map<String, dynamic> toJson() => {'role': role, 'text': text};
}

class AgUiTurnResult {
  const AgUiTurnResult(this.conversationId, this.stopReason);
  final String? conversationId;
  final String stopReason;
}

class AgUiTurn {
  AgUiTurn(this.conversationId, this.done);

  /// Completes once the agent named the conversation (or the turn ended without one).
  final Future<String?> conversationId;

  /// Completes when the turn ends.
  final Future<AgUiTurnResult> done;
}

class AgUiConversation {
  AgUiConversation({
    this.endpoint,
    this.conversationId,
    AgUiSurfaces? surfaces,
    this.fetch = httpFetchStream,
  }) : surfaces = surfaces ?? AgUiSurfaces() {
    this.surfaces.addListener(_surfacesChanged);
    _problems = this.surfaces.problems.listen((p) {
      // Schema findings are logged; the surface renders anyway.
      if (p.code == 'VALIDATION_FAILED') return;
      _emit(AgUiConversationEvent('error', message: p.message));
    });
  }

  final AgUiSurfaces surfaces;
  late final StreamSubscription<AgUiProblemReport> _problems;
  final List<AgUiTranscriptEntry> transcript = [];
  AgentEndpoint? endpoint;
  String? conversationId;
  final AgentFetchStream fetch;

  /// A turn is streaming.
  bool busy = false;
  ({String state, String? tool})? status;

  /// The `prompt` of an embedding widget was sent (once per conversation).
  bool prompted = false;

  /// The unsent text of the chat row.
  String draft = '';

  final List<AgUiConversationListener> _listeners = [];
  Future<void> _queue = Future.value();
  void Function()? _cancel;
  String? _staticKey;
  bool _disposed = false;

  VoidCallback on(AgUiConversationListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _emit(AgUiConversationEvent event) {
    for (final l in List.of(_listeners)) {
      try {
        l(event);
      } catch (e) {
        debugPrint('AG-UI conversation listener failed: $e');
      }
    }
  }

  void _surfacesChanged() => _emit(AgUiConversationEvent('changed'));

  /// A surface fired [action]: reported to listeners, and sent to the agent
  /// when there is one.
  void reportAction(AgUiAction action) {
    _emit(AgUiConversationEvent('action', action: action));
    if (endpoint != null) sendAction(action.toJson());
  }

  /// Render static AG-UI messages (no agent); returns their problems.
  List<AgUiProblemReport> ingest(Iterable<Object?> messages) =>
      surfaces.ingest(messages);

  /// Static messages from a widget prop: re-applied from scratch when they change.
  void syncStatic(Iterable<Object?> messages, String key) {
    if (key == _staticKey) return;
    _staticKey = key;
    surfaces.reset();
    ingest(messages);
  }

  /// Send a user message to the agent.
  AgUiTurn send(String message) {
    transcript.add(AgUiTranscriptEntry('user', message));
    _emit(AgUiConversationEvent('text', text: message, role: 'user'));
    return _turn({'message': message});
  }

  /// Send a client-to-server `action` to the agent.
  AgUiTurn sendAction(Map<String, dynamic> action) =>
      _turn({'action': Map<String, dynamic>.of(action)});

  /// The current data model of [surfaceId] (a copy), or null.
  Object? dataModel(String surfaceId) => surfaces.dataModel(surfaceId);

  /// A JSON summary.
  Map<String, dynamic> describe() => {
        'conversationId': conversationId,
        'busy': busy,
        'surfaces': [
          for (final id in surfaces.surfaceIds)
            {
              'surfaceId': id,
              'catalogId':
                  surfaces.contextFor(id).definition.value?.catalogId,
              'components':
                  surfaces.contextFor(id).definition.value?.components.length ??
                      0,
              'ready': surfaces
                      .contextFor(id)
                      .definition
                      .value
                      ?.components
                      .containsKey('root') ??
                  false,
            }
        ],
        'transcript': [for (final t in transcript) t.toJson()],
      };

  AgUiTurn _turn(Map<String, dynamic> payload) {
    final id = Completer<String?>();
    final done = Completer<AgUiTurnResult>();
    _queue = _queue.then((_) {
      final next = Completer<void>();
      void finish(String stopReason) {
        if (!id.isCompleted) id.complete(conversationId);
        busy = false;
        status = null;
        _cancel = null;
        _emit(AgUiConversationEvent('done',
            stopReason: stopReason, conversationId: conversationId));
        _emit(AgUiConversationEvent('changed'));
        done.complete(AgUiTurnResult(conversationId, stopReason));
        next.complete();
      }

      if (_disposed) {
        finish('error');
        return next.future;
      }
      final ep = endpoint;
      if (ep == null) {
        _emit(AgUiConversationEvent('error',
            message: 'this conversation has no agent endpoint'));
        finish('error');
        return next.future;
      }
      final body = <String, dynamic>{
        ...payload,
        'capabilities': {'supportedCatalogIds': surfaces.supportedCatalogIds},
      };
      if (conversationId != null) body['conversationId'] = conversationId;
      final dataModel = surfaces.clientDataModel();
      if (dataModel != null) body['dataModel'] = dataModel;
      busy = true;
      status = (state: 'working', tool: null);
      _emit(AgUiConversationEvent('changed'));
      String? stopReason;
      _cancel = openAgentStream(
          ep,
          body,
          _Sink(
            onLine: (line) {
              if (line.kind == 'done') stopReason = line.stopReason;
              handleLine(line);
              if (line.kind == 'conversation' && !id.isCompleted) {
                id.complete(line.conversationId);
              }
            },
            onError: (message) =>
                _emit(AgUiConversationEvent('error', message: message)),
            onClose: () => finish(stopReason ?? 'error'),
          ),
          fetch: fetch);
      return next.future;
    });
    return AgUiTurn(id.future, done.future);
  }

  /// Apply one response line (exposed for transports other than HTTP).
  void handleLine(AgentStreamLine line) {
    switch (line.kind) {
      case 'agui':
        final problem = surfaces.handle(line.message);
        if (problem != null) {
          _emit(AgUiConversationEvent('error', message: problem.message));
        }
      case 'conversation':
        conversationId = line.conversationId;
        _emit(AgUiConversationEvent('conversation',
            conversationId: line.conversationId));
      case 'text':
        transcript.add(AgUiTranscriptEntry('agent', line.text ?? ''));
        _emit(AgUiConversationEvent('text', text: line.text, role: 'agent'));
        _emit(AgUiConversationEvent('changed'));
      case 'status':
        status = (state: line.state ?? 'working', tool: line.tool);
        _emit(AgUiConversationEvent('status',
            state: line.state, tool: line.tool));
        _emit(AgUiConversationEvent('changed'));
      case 'error':
        _emit(AgUiConversationEvent('error', message: line.text));
    }
  }

  void dispose() {
    _disposed = true;
    _cancel?.call();
    _cancel = null;
    _listeners.clear();
    _problems.cancel();
    surfaces
      ..removeListener(_surfacesChanged)
      ..dispose();
  }
}

class _Sink implements AgentStreamSink {
  _Sink(
      {required void Function(AgentStreamLine) onLine,
      required void Function(String) onError,
      required void Function() onClose})
      : _line = onLine,
        _error = onError,
        _close = onClose;

  final void Function(AgentStreamLine) _line;
  final void Function(String) _error;
  final void Function() _close;

  @override
  void onLine(AgentStreamLine line) => _line(line);
  @override
  void onError(String message) => _error(message);
  @override
  void onClose() => _close();
}
