/// Server-to-client AG-UI Surface messages as agents and tools actually write them,
/// turned into what agui's processor takes.
///
/// * `version` — `v0.9.1` (the protocol document's spelling) is the same
///   wire format as `v0.9`, the version agui implements.
/// * Templated text — in AG-UI Surface a plain string is a literal: data reaches a
///   component through a binding, `{"path": "/x"}`, or a function call (text
///   mixed with data is `{"call": "formatString", "args": {"value": "High
///   ${/x}°"}}`). Models write templated text as plain strings anyway, in
///   `${…}` or `{{…}}`; both are rewritten here (the node does the same for
///   what it stores, services/pkg/agui; this covers older messages).
library;

import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as core;

final _mustache = RegExp(r'\{\{\s*([A-Za-z0-9_./~\-\[\]]+)\s*\}\}');
final _whole = RegExp(r'^\$\{\s*([A-Za-z0-9_./~\-]+)\s*\}$');

/// Keys that hold component ids and names, never data.
const _structural = {'id', 'component', 'child', 'children', 'componentId'};

/// Rewrites `{{path}}` placeholders as `${path}` (a.b and a[1] become a/b
/// and a/1; relative paths stay relative).
String surfaceInterpolation(String s) {
  if (!s.contains('{{')) return s;
  return s.replaceAllMapped(_mustache, (m) {
    var path = m.group(1)!;
    if (!path.contains('/')) path = path.replaceAll('.', '/');
    path = path.replaceAll('[', '/').replaceAll(']', '');
    return '\${$path}';
  });
}

/// The AG-UI Surface form of a templated string: a binding when it is one
/// placeholder, a formatString call when it mixes text and data, the string
/// itself otherwise.
Object surfaceValue(String s) {
  final t = surfaceInterpolation(s);
  final m = _whole.firstMatch(t);
  if (m != null) return {'path': m.group(1)!};
  if (t.contains(r'${')) {
    return {
      'call': 'formatString',
      'args': {'value': t},
      'returnType': 'string',
    };
  }
  return s;
}

/// Deep copy of decoded JSON with string-keyed maps all the way down.
Object? plainJson(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) '${e.key}': plainJson(e.value)
    };
  }
  if (v is List) return [for (final x in v) plainJson(x)];
  return v;
}

/// [message] normalized: version, templated strings in components.
Map<String, dynamic> normalizeSurfaceMessage(Map<String, dynamic> message) {
  final out = plainJson(message) as Map<String, dynamic>;
  final version = out['version'];
  if (version is! String || version.startsWith('v0.9')) {
    out['version'] = 'v0.9';
  }
  final update = out['updateComponents'];
  if (update is Map<String, dynamic> && update['components'] is List) {
    update['components'] = plainJson([
      for (final c in update['components'] as List)
        if (c is Map<String, dynamic>)
          {
            for (final e in c.entries)
              e.key:
                  _structural.contains(e.key) ? e.value : _normalize(e.value),
          }
        else
          c,
    ]);
  }
  return out;
}

/// Normalizes a list of messages (see [normalizeSurfaceMessage]).
List<Map<String, dynamic>> normalizeSurfaceMessages(
        Iterable<Map<String, dynamic>> messages) =>
    [for (final m in messages) normalizeSurfaceMessage(m)];

/// A data path as agui reads it: `.` (the item a template stands for) and
/// `./x` become the relative `''` and `x`.
String normalizeDataPath(String path) {
  final p = path.trim();
  if (p == '.' || p == './') return '';
  if (p.startsWith('./')) return p.substring(2);
  return p;
}

Object? _normalize(Object? v) {
  if (v is String) return surfaceValue(v);
  if (v is List) return [for (final item in v) _normalize(item)];
  if (v is Map) {
    if (v.containsKey('path')) {
      final path = v['path'];
      return path is String ? {...v, 'path': normalizeDataPath(path)} : v;
    }
    if (v.containsKey('call')) {
      final args = v['args'];
      if (args is! Map) return v;
      return {
        ...v,
        'args': {
          for (final e in args.entries)
            '${e.key}': e.value is String
                ? surfaceInterpolation(e.value as String)
                : _normalize(e.value),
        },
      };
    }
    // An action's event: its name is a name, its context data.
    return {
      for (final e in v.entries)
        '${e.key}': _structural.contains(e.key) || e.key == 'name'
            ? e.value
            : _normalize(e.value),
    };
  }
  return v;
}

/// Parses one message (a decoded JSON map, or its JSON text) into agui's
/// message type, normalized first. Throws [FormatException] for anything
/// that is not an AG-UI Surface server-to-client message.
core.A2uiMessage parseLegacySurfaceMessage(Object? message) {
  final Object? json = message is String ? jsonDecode(message) : message;
  if (json is! Map) {
    throw const FormatException('An AG-UI Surface message must be a JSON object.');
  }
  try {
    return core.A2uiMessage.fromJson(
        normalizeSurfaceMessage(plainJson(json) as Map<String, dynamic>));
  } on core.A2uiValidationError catch (e) {
    throw FormatException(e.message);
  } on TypeError catch (e) {
    throw FormatException('Malformed AG-UI Surface message: $e');
  }
}

/// The server-to-client message kinds.
const List<String> legacySurfaceMessageKinds = [
  'createSurface',
  'updateComponents',
  'updateDataModel',
  'deleteSurface',
];

/// The kind of AG-UI Surface server-to-client message [msg] is, or null when it is
/// not one.
String? legacySurfaceMessageKind(Object? msg) {
  if (msg is! Map) return null;
  for (final k in legacySurfaceMessageKinds) {
    if (msg.containsKey(k)) return k;
  }
  return null;
}
