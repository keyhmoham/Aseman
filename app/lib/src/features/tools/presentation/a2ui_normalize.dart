// In A2UI a plain string is a literal: data reaches a component only through
// a binding, {"path": "/x"}, or a function call — text mixed with data is
// {"call": "formatString", "args": {"value": "High ${/x}°"}}. Models write
// templated text as plain strings anyway, in ${…} or {{…}}, and both then
// render literally (with the path's underscores read as Markdown emphasis).
// The node rewrites what it stores (services/plugins/actions/support/a2ui);
// this does the same for messages stored before it did.

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

/// Messages with the components of every updateComponents normalized (see
/// [a2uiValue]); other messages pass through unchanged.
List<Map<String, dynamic>> normalizeA2uiMessages(
    List<Map<String, dynamic>> messages) {
  return [
    for (final message in messages)
      if (message['updateComponents']
          case {'components': final List<dynamic> list})
        {
          ...message,
          'updateComponents': {
            ...(message['updateComponents'] as Map).cast<String, dynamic>(),
            'components': [
              for (final c in list)
                if (c is Map)
                  {
                    for (final e in c.entries)
                      '${e.key}': _structural.contains(e.key)
                          ? e.value
                          : _normalize(e.value),
                  }
                else
                  c,
            ],
          },
        }
      else
        message,
  ];
}

Object? _normalize(Object? v) {
  if (v is String) return a2uiValue(v);
  if (v is List) return [for (final item in v) _normalize(item)];
  if (v is Map) {
    if (v.containsKey('path')) return v;
    if (v.containsKey('call')) {
      final args = v['args'];
      if (args is! Map) return v;
      return {
        ...v,
        'args': {
          for (final e in args.entries)
            '${e.key}': e.value is String
                ? a2uiInterpolation(e.value as String)
                : e.value,
        },
      };
    }
    return {
      for (final e in v.entries)
        '${e.key}': _structural.contains(e.key) ? e.value : _normalize(e.value),
    };
  }
  return v;
}
