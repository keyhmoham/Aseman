/// Server-to-client A2UI messages as agents and tools actually write them,
/// turned into what genui's processor takes.
///
/// * `version` — `v0.9.1` (the protocol document's spelling) is the same
///   wire format as `v0.9`, the version genui implements.
/// * Templated text — in A2UI a plain string is a literal: data reaches a
///   component through a binding, `{"path": "/x"}`, or a function call (text
///   mixed with data is `{"call": "formatString", "args": {"value": "High
///   ${/x}°"}}`). Models write templated text as plain strings anyway, in
///   `${…}` or `{{…}}`; both are rewritten here (the node does the same for
///   what it stores, services/pkg/a2ui; this covers older messages).
library;

import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as core;

final _mustache = RegExp(r'\{\{\s*([A-Za-z0-9_./~\-\[\]]+)\s*\}\}');
final _whole = RegExp(r'^\$\{\s*([A-Za-z0-9_./~\-]+)\s*\}$');

/// Keys that hold component ids and names, never data.
const _structural = {'id', 'component', 'child', 'children', 'componentId'};

/// Rewrites `{{path}}` placeholders as `${path}` (a.b and a[1] become a/b
/// and a/1; relative paths stay relative).
String a2uiInterpolation(String s) {
  if (!s.contains('{{')) return s;
  return s.replaceAllMapped(_mustache, (m) {
    var path = m.group(1)!;
    if (!path.contains('/')) path = path.replaceAll('.', '/');
    path = path.replaceAll('[', '/').replaceAll(']', '');
    return '\${$path}';
  });
}

/// The A2UI form of a templated string: a binding when it is one
/// placeholder, a formatString call when it mixes text and data, the string
/// itself otherwise.
Object a2uiValue(String s) {
  final t = a2uiInterpolation(s);
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
Map<String, dynamic> normalizeA2uiMessage(Map<String, dynamic> message) {
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

/// Normalizes a list of messages (see [normalizeA2uiMessage]).
List<Map<String, dynamic>> normalizeA2uiMessages(
        Iterable<Map<String, dynamic>> messages) =>
    [for (final m in messages) normalizeA2uiMessage(m)];

/// A data path as genui reads it: `.` (the item a template stands for) and
/// `./x` become the relative `''` and `x`.
String normalizeDataPath(String path) {
  final p = path.trim();
  if (p == '.' || p == './') return '';
  if (p.startsWith('./')) return p.substring(2);
  return p;
}

Object? _normalize(Object? v) {
  if (v is String) return a2uiValue(v);
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
                ? a2uiInterpolation(e.value as String)
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

/// Parses one message (a decoded JSON map, or its JSON text) into genui's
/// message type, normalized first. Throws [FormatException] for anything
/// that is not an A2UI server-to-client message.
core.A2uiMessage parseA2uiMessage(Object? message) {
  final Object? json = message is String ? jsonDecode(message) : message;
  if (json is! Map) {
    throw const FormatException('An A2UI message must be a JSON object.');
  }
  try {
    return core.A2uiMessage.fromJson(
        normalizeA2uiMessage(plainJson(json) as Map<String, dynamic>));
  } on core.A2uiValidationError catch (e) {
    throw FormatException(e.message);
  } on TypeError catch (e) {
    throw FormatException('Malformed A2UI message: $e');
  }
}

/// The server-to-client message kinds.
const List<String> a2uiMessageKinds = [
  'createSurface',
  'updateComponents',
  'updateDataModel',
  'deleteSurface',
];

/// The kind of A2UI server-to-client message [msg] is, or null when it is
/// not one.
String? a2uiMessageKind(Object? msg) {
  if (msg is! Map) return null;
  for (final k in a2uiMessageKinds) {
    if (msg.containsKey(k)) return k;
  }
  return null;
}
