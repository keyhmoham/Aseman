/// AG-UI 1.0 event envelope helpers used by Aseman's surface runtime.
library;

/// AG-UI event type names (1.0).
abstract final class AgUiEventType {
  static const runStarted = 'RUN_STARTED';
  static const runFinished = 'RUN_FINISHED';
  static const runError = 'RUN_ERROR';
  static const stepStarted = 'STEP_STARTED';
  static const stepFinished = 'STEP_FINISHED';
  static const textMessageStart = 'TEXT_MESSAGE_START';
  static const textMessageContent = 'TEXT_MESSAGE_CONTENT';
  static const textMessageEnd = 'TEXT_MESSAGE_END';
  static const textMessageChunk = 'TEXT_MESSAGE_CHUNK';
  static const toolCallStart = 'TOOL_CALL_START';
  static const toolCallArgs = 'TOOL_CALL_ARGS';
  static const toolCallEnd = 'TOOL_CALL_END';
  static const toolCallChunk = 'TOOL_CALL_CHUNK';
  static const toolCallResult = 'TOOL_CALL_RESULT';
  static const stateSnapshot = 'STATE_SNAPSHOT';
  static const stateDelta = 'STATE_DELTA';
  static const messagesSnapshot = 'MESSAGES_SNAPSHOT';
  static const activitySnapshot = 'ACTIVITY_SNAPSHOT';
  static const activityDelta = 'ACTIVITY_DELTA';
  static const raw = 'RAW';
  static const custom = 'CUSTOM';
}

/// Aseman CUSTOM event names for Surface Spec ops.
abstract final class AgUiSurfaceEvent {
  static const create = 'aseman.surface.create';
  static const update = 'aseman.surface.update';
  static const patchData = 'aseman.surface.patchData';
  static const delete = 'aseman.surface.delete';
}

const String asemanCatalogId = 'https://aseman.app/agui/catalogs/aseman/v1';

/// One AG-UI event as a JSON map.
Map<String, dynamic> agUiEvent(String type, [Map<String, dynamic>? fields]) => {
      'type': type,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      ...?fields,
    };

Map<String, dynamic> agUiCustom(String name, Object? value) => agUiEvent(
      AgUiEventType.custom,
      {'name': name, 'value': value},
    );

Map<String, dynamic> agUiStateSnapshot(Object? snapshot) => agUiEvent(
      AgUiEventType.stateSnapshot,
      {'snapshot': snapshot},
    );

/// True when [msg] looks like an AG-UI event object.
bool isAgUiEvent(Object? msg) =>
    msg is Map && msg['type'] is String && (msg['type'] as String).isNotEmpty;
