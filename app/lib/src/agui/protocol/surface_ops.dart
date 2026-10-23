/// Convert between AG-UI surface CUSTOM events and the internal surface
/// message shapes the render engine consumes.
library;

import 'events.dart';

/// Build AG-UI events that create/fill a surface (server → client).
List<Map<String, dynamic>> surfaceEvents({
  required String surfaceId,
  required List<Map<String, dynamic>> components,
  Map<String, dynamic>? data,
  Map<String, dynamic>? theme,
  String catalog = asemanCatalogId,
  String? layout,
}) {
  final themeOut = <String, dynamic>{
    ...?theme,
    if (layout != null && layout.isNotEmpty) 'layout': layout,
  };
  return [
    agUiCustom(AgUiSurfaceEvent.create, {
      'surfaceId': surfaceId,
      'catalog': catalog,
      if (themeOut.isNotEmpty) 'theme': themeOut,
      if (layout != null) 'layout': layout,
    }),
    agUiCustom(AgUiSurfaceEvent.update, {
      'surfaceId': surfaceId,
      'components': _normalizeComponents(components),
    }),
    if (data != null)
      agUiCustom(AgUiSurfaceEvent.patchData, {
        'surfaceId': surfaceId,
        'path': '/',
        'value': data,
      }),
    agUiStateSnapshot({
      'aseman.surfaces': {
        surfaceId: {
          'catalog': catalog,
          if (themeOut.isNotEmpty) 'theme': themeOut,
          'components': _normalizeComponents(components),
          if (data != null) 'data': data,
        },
      },
    }),
  ];
}

/// Prefer `"type"`; accept legacy `"component"`.
List<Map<String, dynamic>> _normalizeComponents(
    List<Map<String, dynamic>> components) {
  return [
    for (final c in components)
      {
        ...c,
        if (c['type'] == null && c['component'] != null)
          'type': c['component'],
        // Render engine (genui) still keys off "component".
        if (c['component'] == null && c['type'] != null)
          'component': c['type'],
      },
  ];
}

/// Translate one AG-UI event into zero or more legacy surface messages
/// (`createSurface` / `updateComponents` / `updateDataModel` / `deleteSurface`)
/// for the render engine. Returns null when the event is not a surface op.
List<Map<String, dynamic>>? agUiEventToSurfaceMessages(Object? event) {
  if (event is! Map) return null;
  final type = event['type'];
  if (type == AgUiEventType.custom) {
    final name = event['name'];
    final value = event['value'];
    if (value is! Map) return null;
    final surfaceId = '${value['surfaceId'] ?? ''}';
    if (surfaceId.isEmpty) return null;
    switch (name) {
      case AgUiSurfaceEvent.create:
        final theme = value['theme'] is Map
            ? Map<String, dynamic>.from(value['theme'] as Map)
            : <String, dynamic>{};
        if (value['layout'] is String && theme['layout'] == null) {
          theme['layout'] = value['layout'];
        }
        return [
          {
            'version': 'v0.9',
            'createSurface': {
              'surfaceId': surfaceId,
              'catalogId': value['catalog'] ?? asemanCatalogId,
              if (theme.isNotEmpty) 'theme': theme,
            },
          },
        ];
      case AgUiSurfaceEvent.update:
        final comps = value['components'];
        if (comps is! List) return null;
        return [
          {
            'version': 'v0.9',
            'updateComponents': {
              'surfaceId': surfaceId,
              'components': _normalizeComponents([
                for (final c in comps)
                  if (c is Map) Map<String, dynamic>.from(c),
              ]),
            },
          },
        ];
      case AgUiSurfaceEvent.patchData:
        return [
          {
            'version': 'v0.9',
            'updateDataModel': {
              'surfaceId': surfaceId,
              'path': value['path'] ?? '/',
              'value': value['value'],
            },
          },
        ];
      case AgUiSurfaceEvent.delete:
        return [
          {
            'version': 'v0.9',
            'deleteSurface': {'surfaceId': surfaceId},
          },
        ];
    }
  }
  if (type == AgUiEventType.stateSnapshot) {
    final snapshot = event['snapshot'];
    if (snapshot is! Map) return null;
    final surfaces = snapshot['aseman.surfaces'];
    if (surfaces is! Map) return null;
    final out = <Map<String, dynamic>>[];
    for (final e in surfaces.entries) {
      final id = '${e.key}';
      final s = e.value;
      if (s is! Map) continue;
      final theme = s['theme'] is Map
          ? Map<String, dynamic>.from(s['theme'] as Map)
          : <String, dynamic>{};
      out.add({
        'version': 'v0.9',
        'createSurface': {
          'surfaceId': id,
          'catalogId': s['catalog'] ?? asemanCatalogId,
          if (theme.isNotEmpty) 'theme': theme,
        },
      });
      final comps = s['components'];
      if (comps is List) {
        out.add({
          'version': 'v0.9',
          'updateComponents': {
            'surfaceId': id,
            'components': _normalizeComponents([
              for (final c in comps)
                if (c is Map) Map<String, dynamic>.from(c),
            ]),
          },
        });
      }
      if (s.containsKey('data')) {
        out.add({
          'version': 'v0.9',
          'updateDataModel': {
            'surfaceId': id,
            'path': '/',
            'value': s['data'],
          },
        });
      }
    }
    return out.isEmpty ? null : out;
  }
  return null;
}

/// Expand a list of AG-UI events and/or legacy surface messages into only
/// legacy surface messages for the render engine.
List<Map<String, dynamic>> expandToSurfaceMessages(
    Iterable<Object?> events) {
  final out = <Map<String, dynamic>>[];
  for (final e in events) {
    if (e is! Map) continue;
    final mapped = agUiEventToSurfaceMessages(e);
    if (mapped != null) {
      out.addAll(mapped);
      continue;
    }
    // Legacy surface messages still accepted for stored payloads; prefer
    // AG-UI. Normalize type→component (copy deeply — const test fixtures
    // and JSON-decoded maps may be unmodifiable).
    if (e.containsKey('createSurface') ||
        e.containsKey('updateComponents') ||
        e.containsKey('updateDataModel') ||
        e.containsKey('deleteSurface')) {
      final copy = Map<String, dynamic>.from(e);
      final update = copy['updateComponents'];
      if (update is Map && update['components'] is List) {
        copy['updateComponents'] = {
          ...Map<String, dynamic>.from(update),
          'components': _normalizeComponents([
            for (final c in update['components'] as List)
              if (c is Map) Map<String, dynamic>.from(c),
          ]),
        };
      }
      out.add(copy);
    }
  }
  return out;
}
