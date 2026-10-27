// Keeps the UI DSL validator's layout facts true: renders every node type
// directly in a Row, in a vertical scroll and in a horizontal scroll, and
// checks that the nodes that throw there are exactly the ones the validator's
// schema (appui/elpian/schema.mjs, LAYOUT) says need a width / height bound or
// a particular parent.
import 'dart:convert';
import 'dart:io';

import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/elpian/core/elpian_engine.dart' show NodeErrorBox;
import 'package:aseman/src/features/tools/ui_kit/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _kit = '../deploy/sandbox-computer/appui/elpian';

const _rows = [
  {'label': 'A', 'value': 3, 'x': 'a', 'y': 'b'},
  {'label': 'B', 'value': 5, 'x': 'b', 'y': 'a'},
];

// Enough props for each node to draw something.
const Map<String, Map<String, dynamic>> _sample = {
  'Text': {'text': 'hi'},
  'Icon': {'icon': 'home'},
  'Chart': {'type': 'bar', 'data': _rows, 'x': 'label', 'y': 'value'},
  'Sparkline': {'values': [1, 2, 3]},
  'Gauge': {'value': 3},
  'Heatmap': {'data': _rows},
  'Treemap': {'data': _rows, 'label': 'label', 'value': 'value'},
  'Graph': {
    'nodes': [{'id': 'a'}, {'id': 'b'}],
    'edges': [{'from': 'a', 'to': 'b'}]
  },
  'DataGrid': {
    'data': _rows,
    'columns': [{'field': 'label'}]
  },
  'Stat': {'label': 'L', 'value': 3},
  'KeyValue': {
    'items': [{'label': 'a', 'value': 1}]
  },
  'Timeline': {
    'data': [{'title': 't'}]
  },
  'TreeView': {'data': {'label': 'r'}},
  'JsonView': {'value': {'a': 1}},
  'CodeBlock': {'code': 'x'},
  'Progress': {'value': 0.5},
  'Tag': {'text': 't'},
  'Callout': {'text': 't'},
  'Avatar': {'name': 'A B'},
  'Section': {'title': 't'},
  'Expandable': {'title': 't'},
  'SegmentedButton': {'segments': ['a', 'b']},
  'NavigationBar': {
    'items': [
      {'icon': 'home', 'label': 'a'},
      {'icon': 'add', 'label': 'b'}
    ]
  },
  'ListTile': {'title': 't'},
  'Button': {'text': 'b'},
  'Chip': {'label': 'c'},
  'Badge': {'label': '1'},
  'Tooltip': {'message': 'm'},
  'IndexedStack': {'index': 0},
  'Funnel': {'data': _rows},
  'Waterfall': {'data': _rows, 'start': 2},
  'Sankey': {
    'links': [
      {'from': 'a', 'to': 'b', 'value': 3},
      {'from': 'b', 'to': 'c', 'value': 2}
    ]
  },
  'Gantt': {
    'data': [
      {'label': 't', 'start': '2026-01-01', 'end': '2026-01-09', 'progress': 0.5}
    ]
  },
  'BoxPlot': {
    'data': [
      {'label': 'a', 'values': [1, 2, 3, 4, 9]}
    ]
  },
  'BulletChart': {'label': 'L', 'value': 3, 'target': 4, 'ranges': [2, 4, 6]},
  'SegmentedBar': {'data': _rows},
  'RadialBars': {'data': _rows},
  'Sunburst': {
    'data': [
      {'label': 'a', 'children': [{'label': 'b', 'value': 2}]},
      {'label': 'c', 'value': 1}
    ]
  },
  'CalendarHeatmap': {
    'data': [
      {'date': '2026-01-05', 'value': 3}
    ],
    'weeks': 8
  },
  'WordCloud': {
    'data': [
      {'text': 'alpha', 'value': 3},
      {'text': 'beta', 'value': 1}
    ]
  },
  'PivotTable': {'data': _rows, 'rows': 'label', 'columns': 'x', 'value': 'value'},
  'Leaderboard': {'data': [{'name': 'A', 'value': 3}, {'name': 'B', 'value': 2}]},
  'Tabs': {'tabs': ['One', 'Two']},
  'Calendar': {'month': '2026-01', 'selected': '2026-01-05', 'events': [{'date': '2026-01-05', 'title': 'x'}]},
  'Kanban': {
    'columns': [
      {'title': 'A', 'cards': [{'title': 'c'}]}
    ]
  },
  'Carousel': {'height': 120},
  'Stepper': {'steps': ['a', 'b'], 'current': 0},
  'Chat': {
    'messages': [
      {'role': 'user', 'text': 'hi'},
      {'role': 'assistant', 'text': 'hello'}
    ],
    'suggestions': ['more']
  },
  'Countdown': {'seconds': 90},
  'Clock': {'label': 'Here'},
  'EmptyState': {'title': 'Nothing', 'action': 'Add'},
  'AvatarGroup': {'names': ['A B', 'C D']},
  'Pagination': {'page': 2, 'pages': 5},
  'Breadcrumbs': {'items': ['Home', 'Here']},
  'Markdown': {'text': '# Hi\n\n- a\n\n| a | b |\n|---|---|\n| 1 | 2 |'},
  'LogView': {'lines': ['INFO ok', 'ERROR bad']},
  'DiffView': {'before': 'a\nb', 'after': 'a\nc'},
  'QRCode': {'data': 'https://aseman.app'},
};

// Not measurable here: platform views, drag-and-drop and route transitions.
const _skip = {'Scene3D', 'scene3d', 'Canvas', 'CachedCanvas', 'Hero', 'Draggable', 'DragTarget', 'Dismissible'};

List<String> _list(String src, String name) {
  final m = RegExp('$name: \\[([^\\]]*)\\]').firstMatch(src)!;
  return RegExp('"(\\w+)"').allMatches(m.group(1)!).map((m) => m.group(1)!).toList()..sort();
}

void main() {
  final schema = File('$_kit/schema.mjs').readAsStringSync();
  final layout = schema.substring(schema.indexOf('export const LAYOUT'));
  final needsWidth = _list(layout, 'needsWidth');
  final needsHeight = _list(layout, 'needsHeight');
  final parents = (RegExp(r'parents: \{([^}]*)\}').firstMatch(layout)!.group(1)!)
      .split('],')
      .map((e) => RegExp(r'(\w+):').firstMatch(e)?.group(1))
      .whereType<String>()
      .toList()
    ..sort();
  final nodes = jsonDecode(File('$_kit/nodes.json').readAsStringSync());
  final types = <String>{...nodes['elpian'], ...nodes['kit']}..removeAll(_skip);

  final throwsIn = <String, Set<String>>{'row': {}, 'vscroll': {}, 'hscroll': {}, 'parent': {}};

  for (final type in types) {
    testWidgets('$type in unbounded layouts', (tester) async {
      for (final where in ['row', 'vscroll', 'hscroll']) {
        final engine = kitEngine();
        final node = {
          'type': type,
          'props': _sample[type] ?? {'text': 'x', 'label': 'x', 'title': 'x'},
          'children': [
            {'type': 'Text', 'props': {'text': 'child'}}
          ],
        };
        Widget w = Builder(builder: (_) => engine.renderFromJson(node));
        w = switch (where) {
          'row' => Row(children: [w]),
          'vscroll' => SingleChildScrollView(child: w),
          _ => SingleChildScrollView(scrollDirection: Axis.horizontal, child: w),
        };
        final errors = <String>[];
        final old = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString());
        await tester.pumpWidget(MaterialApp(theme: AppTheme.light, home: Scaffold(body: w)));
        await tester.pump(const Duration(milliseconds: 100));
        final e = tester.takeException();
        FlutterError.onError = old;
        if (e != null) errors.add('$e');
        if (errors.isEmpty) continue;
        if (errors.any((m) => m.contains('Incorrect use of ParentDataWidget'))) {
          throwsIn['parent']!.add(type);
        } else {
          throwsIn[where]!.add(type);
        }
        await tester.pumpWidget(const SizedBox());
      }
    });
  }

  test('the validator knows exactly which nodes need a bound or a parent', () {
    final width = {...throwsIn['row']!, ...throwsIn['hscroll']!}.toList()..sort();
    final height = throwsIn['vscroll']!.toList()..sort();
    final parent = throwsIn['parent']!.toList()..sort();
    expect(width, needsWidth, reason: 'schema.mjs LAYOUT.needsWidth');
    expect(height, needsHeight, reason: 'schema.mjs LAYOUT.needsHeight');
    expect(parent, parents, reason: 'schema.mjs LAYOUT.parents');
  });

  // What the validator calls an error really breaks; what it lets through
  // really renders (the same cases validate.test.mjs checks the verdicts of).
  final cases = (jsonDecode(File('test/elpian/fixtures/validator_cases.json').readAsStringSync())['cases'] as List).cast<Map<String, dynamic>>();
  for (final c in cases) {
    testWidgets('validator case: ${c['name']} ${c['flutter']}', (tester) async {
      final errors = <String>[];
      final old = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString());
      try {
        final engine = kitEngine();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: Builder(builder: (_) => engine.renderFromJson(c['tree'] as Map<String, dynamic>))),
        ));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (e) {
        errors.add('$e');
      } finally {
        FlutterError.onError = old;
      }
      final e = tester.takeException();
      if (e != null) errors.add('$e');
      // A node whose builder threw draws its inline error box instead.
      // (Only looked for when layout succeeded: a broken tree is not walkable.)
      final boxed = errors.isEmpty && find.byType(NodeErrorBox).evaluate().isNotEmpty;
      if (c['flutter'] == 'breaks') {
        expect(errors.isNotEmpty || boxed, isTrue, reason: 'the validator calls this an error, but it rendered');
      } else {
        expect(errors, isEmpty, reason: 'the validator lets this through, but it threw: ${errors.isEmpty ? '' : errors.first.split('\n').first}');
        expect(boxed, isFalse, reason: 'the validator lets this through, but a node failed to build');
      }
    });
  }
}
