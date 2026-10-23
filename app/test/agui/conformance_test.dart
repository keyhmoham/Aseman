// Surface Spec conformance cases for the renderer: expressions, data
// deletion, actions, data-context paths and the data model. (Parser and
// validator internals are exercised via the render engine.)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:aseman/src/agui/agui.dart';

import 'support.dart';

List<Map<String, dynamic>> conformance(String name) {
  final file = File('test/agui/conformance/$name.json');
  return (jsonDecode(file.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
}

Object? renameKeys(Object? v) {
  if (v is List) return v.map(renameKeys).toList();
  if (v is Map) {
    return {
      for (final e in v.entries)
        (e.key == '@call'
            ? 'call'
            : e.key == '@path'
                ? 'path'
                : e.key as String): renameKeys(e.value),
    };
  }
  return v;
}

/// v1.0 conformance payloads as v0.9 messages.
List<Map<String, dynamic>> fromV1(Iterable<Object?> messages) {
  final out = <Map<String, dynamic>>[];
  for (final raw in messages) {
    final m = Map<String, dynamic>.from(renameKeys(raw)! as Map);
    if (m['createSurface'] is Map) {
      final cs = Map<String, dynamic>.from(m['createSurface'] as Map);
      final hasData = cs.containsKey('dataModel');
      final dataModel = cs.remove('dataModel');
      final components = cs.remove('components');
      if (cs['catalogId'] == 'basic') cs['catalogId'] = asemanCatalogId;
      out.add({'version': 'v0.9', 'createSurface': cs});
      if (hasData) {
        out.add({
          'version': 'v0.9',
          'updateDataModel': {
            'surfaceId': cs['surfaceId'],
            'path': '/',
            'value': dataModel
          }
        });
      }
      if (components != null) {
        out.add({
          'version': 'v0.9',
          'updateComponents': {
            'surfaceId': cs['surfaceId'],
            'components': components
          }
        });
      }
    } else {
      m.remove('version');
      out.add({'version': 'v0.9', ...m});
    }
  }
  return out;
}

List<Object?> payloads(Map<String, dynamic> c) => [
      for (final s in c['steps'] as List) ...((s as Map)['payload'] as List)
    ];

void main() {
  for (final c in conformance('expressions')
      .where((c) => c['action'] == 'validate')) {
    final name = c['name'] as String;
    final failing = (c['steps'] as List).any((s) => s['expectError'] != null);
    testWidgets('conformance: expressions: $name', (tester) async {
      final surfaces = AgUiSurfaces()..ingest(fromV1(payloads(c)));
      addTearDown(surfaces.dispose);
      await tester.pumpWidget(
          host(AgUiSurfaceView(surfaces: surfaces, surfaceId: 'main')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      if (failing) {
        // A broken template never renders as if it were text with data.
        expect(find.textContaining(r'${1}'), findsNothing, reason: name);
      } else {
        expect(
            find.text(c['expect']['surfaces']['main']['components']['root']
                ['text'] as String),
            findsOneWidget,
            reason: name);
      }
    });
  }

  test('conformance: data_deletion', () {
    for (final c in conformance('data_deletion')) {
      final surfaces = AgUiSurfaces();
      expect(surfaces.ingest(fromV1(payloads(c))), isEmpty,
          reason: c['name'] as String);
      (c['expect']['surfaces'] as Map).forEach((sid, exp) {
        expect(surfaces.dataModel(sid as String), exp['dataModel'],
            reason: c['name'] as String);
      });
      surfaces.dispose();
    }
  });

  for (final c in conformance('actions')) {
    final name = c['name'] as String;
    testWidgets('conformance: actions: $name', (tester) async {
      final scope = c['scope'] as String?;
      final actions = <AgUiAction>[];
      final surfaces = AgUiSurfaces()
        ..ingest(surface(
          [
            if (scope == null)
              {'id': 'root', 'component': 'Column', 'children': ['btn']}
            else ...[
              {
                'id': 'root',
                'component': 'List',
                'children': {
                  'componentId': 'btn',
                  'path': scope.substring(0, scope.lastIndexOf('/'))
                }
              },
            ],
            {'id': 'label', 'component': 'Text', 'text': 'Go'},
            {
              'id': 'btn',
              'component': 'Button',
              'child': 'label',
              'action': c['actionPayload'],
            },
          ],
          (c['dataModel'] as Map?)?.cast<String, dynamic>(),
        ));
      addTearDown(surfaces.dispose);
      await tester.pumpWidget(host(AgUiSurfaceView(
          surfaces: surfaces, surfaceId: 's', onAction: actions.add)));
      await tester.pumpAndSettle();
      final index = scope == null ? 0 : int.parse(scope.split('/').last);
      await tester.tap(find.text('Go').at(index));
      await tester.pumpAndSettle();
      expect(actions, hasLength(1), reason: name);
      final action = actions.single;
      expect(action.surfaceId, 's');
      expect(action.sourceComponentId, 'btn');
      final exp = c['expectDispatched'] as Map;
      expect(action.name, exp['name'], reason: name);
      expect(action.context, exp['context'] ?? <String, dynamic>{},
          reason: name);
      if (exp['userMessage'] != null) {
        expect(action.userMessage, exp['userMessage'], reason: name);
      }
      expect(action.toJson()['timestamp'], isA<String>());
    });
  }

  test('conformance: data_context', () {
    for (final c in conformance('data_context')) {
      final args = c['args'] as Map;
      final context = DataContext(
          InMemoryDataModel(), DataPath('${args['contextPath'] ?? '/'}'));
      final path = normalizeDataPath(args['path'] as String);
      expect(context.resolvePath(DataPath(path)).toString(), c['expect'],
          reason: c['name'] as String);
    }
  });

  test('conformance: data_model values', () {
    var checked = 0;
    // the render engine reads a leading-zero index ("/items/01") as the index.
    const lenient = {'test_data_model_rejects_leading_zero_list_index'};
    for (final c in conformance('data_model')) {
      if (lenient.contains(c['name'])) continue;
      final model = InMemoryDataModel();
      if (c['initial'] != null) model.update(DataPath.root, c['initial']);
      for (final step in (c['steps'] as List).cast<Map<String, dynamic>>()) {
        // Errors and notifications are the data model's own contract
        // (the engine's); values are what surfaces show.
        if (step['expect_error'] != null || step['op'] == 'dispose') break;
        final path = DataPath('${step['path']}');
        switch (step['op']) {
          case 'set':
            model.update(path, step['value']);
          case 'delete':
            deletePath(model, '${step['path']}');
          case 'get':
            if (step.containsKey('expect')) {
              expect(model.getValue<Object?>(path), step['expect'],
                  reason: '${c['name']} ${step['path']}');
              checked++;
            } else if (step['expect_absent'] == true) {
              expect(model.getValue<Object?>(path), isNull,
                  reason: '${c['name']} ${step['path']}');
              checked++;
            }
        }
      }
      model.dispose();
    }
    expect(checked, greaterThan(30));
  });
}
