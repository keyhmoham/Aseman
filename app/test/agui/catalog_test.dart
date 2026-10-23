// Aseman Surface Spec catalog (catalog.json and examples) and basic
// component behaviour: two-way binding, checks, actions, Tabs, Modal,
// theme, and client functions.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:aseman/src/agui/agui.dart';

import 'support.dart';

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File('test/agui/$path').readAsStringSync())
        as Map<String, dynamic>;

List<({String file, Map<String, dynamic> json})> examples() {
  final dir = Directory('test/agui/spec/catalogs/basic/examples');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final f in files)
      (
        file: f.uri.pathSegments.last,
        json: jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
      )
  ];
}

void main() {
  test('the catalog covers the basic catalog of catalog.json', () {
    final json = readJson('spec/catalogs/basic/catalog.json');
    expect(asemanCatalog.catalogId, json['catalogId']);
    final components = json['components'] as Map<String, dynamic>;
    final items = {for (final i in asemanCatalog.items) i.name: i};
    components.forEach((name, schema) {
      final item = items[name];
      expect(item, isNotNull, reason: name);
      final allOf = (schema['allOf'] as List).cast<Map<String, dynamic>>();
      final own = allOf.firstWhere(
          (a) => (a['properties'] as Map?)?.containsKey('component') == true);
      final props = (own['properties'] as Map)
          .keys
          .where((p) => p != 'component')
          .toSet();
      final ours =
          (item!.dataSchema.value['properties']! as Map<String, Object?>)
              .keys
              .toSet();
      expect(ours.containsAll(props), isTrue,
          reason: '$name lacks ${props.difference(ours)}');
      final checkable =
          allOf.any((a) => '${a[r'$ref'] ?? ''}'.endsWith('Checkable'));
      if (checkable) expect(ours, contains('checks'), reason: name);
      final required = (item.dataSchema.value['required'] as List).toSet();
      expect(
          required.containsAll(
              (own['required'] as List).where((r) => r != 'component')),
          isTrue,
          reason: '$name required');
    });
    final functions = {for (final f in asemanCatalog.functions) f.name};
    expect(functions.containsAll((json['functions'] as Map).keys), isTrue);
    final iconEnum = components['Icon']['allOf'][2]['properties']['name']
        ['oneOf'][0]['enum'] as List;
    for (final name in iconEnum) {
      expect(agUiIcon(name), isNotNull, reason: 'icon $name');
    }
  });

  test('component names are unique and every group is non-empty', () {
    final names = asemanComponentNames.toList();
    expect(names.toSet(), hasLength(names.length));
    for (final group in asemanComponentGroups.entries) {
      expect(group.value, isNotEmpty, reason: group.key);
    }
    // Every Aseman component of the previous catalog is still here.
    expect(
        names,
        containsAll([
          'Chart', 'Sparkline', 'Gauge', 'Heatmap', 'Treemap', 'Graph', //
          'Table', 'Stat', 'KeyValue', 'Timeline', 'TreeView', 'JsonView',
          'CodeBlock', 'Progress', 'Badge', 'Rating', 'Callout', 'Avatar',
          'Grid', 'Wrap', 'Stack', 'Box', 'Center', 'Spacer', 'AspectRatio',
          'Scroll', 'Section', 'Expandable', 'Switch', 'Elpian',
          'ToolFrontend',
        ]));
  });

  final all = examples();
  test('there are 43 basic catalog examples', () => expect(all, hasLength(43)));

  for (final example in all) {
    testWidgets('example ${example.file} renders', (tester) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final surfaces = AgUiSurfaces();
      addTearDown(surfaces.dispose);
      final problems = <AgUiProblemReport>[];
      final sub = surfaces.problems.listen(problems.add);
      addTearDown(sub.cancel);
      problems.addAll(surfaces.ingest(example.json['messages'] as List));
      expect(surfaces.surfaceIds, isNotEmpty);
      await tester.pumpWidget(host(Column(children: [
        for (final id in surfaces.surfaceIds)
          AgUiSurfaceView(surfaces: surfaces, surfaceId: id),
      ])));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(problems.map((p) => '${p.code}: ${p.message}'), isEmpty);
      expect(find.byType(FallbackWidget), findsNothing);
      expect(find.byType(Surface), findsWidgets);
      expect(tester.getSize(find.byType(Surface).first).height,
          greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('two-way binding, checks, actions and the surface theme',
      (tester) async {
    final actions = <AgUiAction>[];
    final messages = [
      {
        'version': 'v0.9.1',
        'createSurface': {
          'surfaceId': 'f',
          'catalogId': asemanCatalogId,
          'theme': {'primaryColor': '#00BFFF'}
        }
      },
      {
        'version': 'v0.9.1',
        'updateComponents': {
          'surfaceId': 'f',
          'components': [
            {
              'id': 'root',
              'component': 'Column',
              'children': ['name', 'echo', 'go']
            },
            {
              'id': 'name',
              'component': 'TextField',
              'label': 'Name',
              'value': {'path': '/form/name'},
              'checks': [requiredCheck('/form/name')],
            },
            {
              'id': 'echo',
              'component': 'Text',
              'text': {
                'call': 'formatString',
                'args': {'value': r'Hi ${/form/name}'},
                'returnType': 'string'
              }
            },
            {'id': 'go_label', 'component': 'Text', 'text': 'Go'},
            {
              'id': 'go',
              'component': 'Button',
              'child': 'go_label',
              'variant': 'primary',
              'action': {
                'event': {
                  'name': 'submit',
                  'context': {
                    'name': {'path': '/form/name'}
                  }
                }
              },
              'checks': [requiredCheck('/form/name')],
            },
          ]
        }
      },
    ];
    final surfaces = AgUiSurfaces()..ingest(messages);
    addTearDown(surfaces.dispose);
    await tester.pumpWidget(host(AgUiSurfaceView(
        surfaces: surfaces, surfaceId: 'f', onAction: actions.add)));
    await tester.pumpAndSettle();
    FilledButton button() => tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull, reason: 'the check fails');
    // The surface's primary color reaches the primary button.
    expect(Theme.of(tester.element(find.byType(FilledButton))).colorScheme.primary,
        isNot(Theme.of(tester.element(find.byType(AgUiSurfaceView))).colorScheme.primary));

    await tester.enterText(find.byType(TextField), 'Ada');
    await tester.pumpAndSettle();
    expect(surfaces.dataModel('f'), {
      'form': {'name': 'Ada'}
    });
    expect(find.text('Hi Ada'), findsOneWidget);
    expect(button().onPressed, isNotNull);
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(actions, hasLength(1));
    expect(actions.single.name, 'submit');
    expect(actions.single.surfaceId, 'f');
    expect(actions.single.sourceComponentId, 'go');
    expect(actions.single.context, {'name': 'Ada'});

    // The agent updates the data model: the field follows.
    surfaces.handle({
      'version': 'v0.9.1',
      'updateDataModel': {
        'surfaceId': 'f',
        'path': '/form/name',
        'value': 'Grace'
      }
    });
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Grace');
    expect(find.text('Hi Grace'), findsOneWidget);
  });

  testWidgets('Modal opens its content in a dialog and closes', (tester) async {
    final surfaces = AgUiSurfaces()
      ..ingest(readJson('spec/catalogs/basic/examples/36_modal.json')['messages']
          as List);
    addTearDown(surfaces.dispose);
    await tester.pumpWidget(host(AgUiSurfaceView(
        surfaces: surfaces, surfaceId: surfaces.surfaceIds.first)));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    await tester.tap(find.byWidgetPredicate((w) => w is ButtonStyleButton).first);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('Tabs switch, and write the open tab when bound',
      (tester) async {
    final surfaces = AgUiSurfaces()
      ..ingest(surface([
        {
          'id': 'root',
          'component': 'Tabs',
          'selected': {'path': '/tab'},
          'tabs': [
            {'title': 'Orders', 'child': 'a'},
            {'title': 'Fills', 'child': 'b'},
          ]
        },
        {'id': 'a', 'component': 'Text', 'text': 'Open orders'},
        {'id': 'b', 'component': 'Text', 'text': 'Recent fills'},
      ]));
    addTearDown(surfaces.dispose);
    await tester.pumpWidget(
        host(AgUiSurfaceView(surfaces: surfaces, surfaceId: 's')));
    await tester.pumpAndSettle();
    expect(find.text('Open orders'), findsOneWidget);
    await tester.tap(find.text('Fills'));
    await tester.pumpAndSettle();
    expect(find.text('Recent fills'), findsOneWidget);
    expect(find.text('Open orders'), findsNothing);
    expect(surfaces.dataModel('s'), {'tab': 1});
  });

  testWidgets('Text renders Markdown, and plain text as plain Text',
      (tester) async {
    final surfaces = AgUiSurfaces()
      ..ingest(surface([
        {
          'id': 'root',
          'component': 'Column',
          'children': ['plain', 'md']
        },
        {'id': 'plain', 'component': 'Text', 'text': 'price_change_pct'},
        {'id': 'md', 'component': 'Text', 'text': 'Buy **AAPL** now'},
      ]));
    addTearDown(surfaces.dispose);
    await tester.pumpWidget(
        host(AgUiSurfaceView(surfaces: surfaces, surfaceId: 's')));
    await tester.pumpAndSettle();
    expect(find.text('price_change_pct'), findsOneWidget);
    expect(find.textContaining('AAPL', findRichText: true), findsWidgets);
    expect(find.textContaining('**'), findsNothing);
  });

  group('functions', () {
    test('basic catalog functions follow the spec', () async {
      expect(await call('formatNumber', {'value': 1234.5, 'decimals': 2}),
          '1,234.50');
      expect(
          await call('formatNumber',
              {'value': 1234.5, 'decimals': 0, 'grouping': false}),
          '1235');
      expect(await call('formatCurrency', {'value': 49.99, 'currency': 'EUR'}),
          '€49.99');
      expect(
          await call('formatCurrency', {'value': -1234.5, 'currency': 'USD'}),
          r'-$1,234.50');
      expect(
          await call('formatDate',
              {'value': '2026-02-02T15:17:00', 'format': "EEEE, MMM d 'at' h:mm a"}),
          'Monday, Feb 2 at 3:17 PM');
      expect(
          await call(
              'pluralize', {'value': 1, 'one': 'item', 'other': 'items'}),
          'item');
      expect(
          await call(
              'pluralize', {'value': 3, 'one': 'item', 'other': 'items'}),
          'items');
      expect(
          await call(
              'pluralize', {'value': 0, 'zero': 'none', 'other': 'items'}),
          'none');
      expect(await call('required', {'value': <Object?>[]}), false);
      expect(await call('email', {'value': 'a@b.co'}), true);
      expect(await call('email', {'value': 'not an email'}), false);
      expect(await call('length', {'value': 'abc', 'min': 4}), false);
      expect(await call('numeric', {'value': '5', 'min': 1, 'max': 10}), true);
      expect(
          await call('regex', {'value': '12345', 'pattern': r'^[0-9]{5}$'}),
          true);
      expect(
          await call('and', {
            'values': [
              true,
              {
                'call': 'not',
                'args': {'value': false}
              }
            ]
          }),
          true);
      expect(
          await call('or', {
            'values': [false, false]
          }),
          false);
      await expectLater(call('openUrl', {'url': 'javascript:alert(1)'}),
          throwsA(isA<FormatException>()));
      expect(await call('nope', {}), isNull);
    });

    test('Aseman functions', () async {
      expect(await call('format', {'value': 0.1234, 'format': '+percent:1'}),
          '+12.3%');
      expect(await call('formatPercent', {'value': 0.05, 'signed': true}),
          '+5.0%');
      expect(await call('formatCompact', {'value': 12900}), '12.9K');
      expect(
          await call('add', {
            'values': [1, 2, 3.5]
          }),
          6.5);
      expect(await call('subtract', {'a': 10, 'b': 4}), 6);
      expect(
          await call('multiply', {
            'values': [2, 3]
          }),
          6);
      expect(await call('divide', {'a': 1, 'b': 0}), isNull);
      expect(await call('round', {'value': 3.14159, 'decimals': 2}), 3.14);
      expect(await call('clamp', {'value': 12, 'min': 0, 'max': 10}), 10);
      expect(await call('percentChange', {'from': 100, 'to': 110}),
          closeTo(0.1, 1e-9));
      final rows = [
        {'v': 1},
        {'v': 3},
        {'v': 8}
      ];
      expect(await call('sum', {'values': rows, 'field': 'v'}), 12);
      expect(await call('average', {'values': rows, 'field': 'v'}), 4);
      expect(await call('min', {'values': rows, 'field': 'v'}), 1);
      expect(await call('max', {'values': rows, 'field': 'v'}), 8);
      expect(await call('count', {'values': rows}), 3);
      expect(await call('equals', {'a': '5', 'b': 5}), true);
      expect(await call('greaterThan', {'a': 3, 'b': 2}), true);
      expect(await call('lessThan', {'a': 'a', 'b': 'b'}), true);
      expect(await call('isEmpty', {'value': ''}), true);
      expect(
          await call('contains', {
            'value': ['a', 'b'],
            'item': 'b'
          }),
          true);
      expect(await call('if', {'condition': true, 'then': 'yes', 'else': 'no'}),
          'yes');
      expect(
          await call('coalesce', {
            'values': [null, '', 'x']
          }),
          'x');
      expect(
          await call('concat', {
            'values': ['a', 1],
            'separator': '-'
          }),
          'a-1');
      expect(
          await call('join', {
            'values': [
              {'n': 'A'},
              {'n': 'B'}
            ],
            'field': 'n'
          }),
          'A, B');
      expect(await call('truncate', {'value': 'abcdef', 'max': 4}), 'abc…');
      expect(
          await call('get', {
            'value': {
              'quote': {'price': 9}
            },
            'path': 'quote.price'
          }),
          9);
      expect(
          await call('formatRelative', {
            'value': DateTime.now()
                .subtract(const Duration(minutes: 5))
                .toIso8601String()
          }),
          '5 min ago');
      expect(await call('now', {'format': 'yyyy'}), '${DateTime.now().year}');
    });

    test('client-side state functions write the data model', () async {
      final model = InMemoryDataModel();
      final context =
          DataContext(model, DataPath.root, functions: asemanCatalog.functions);
      Future<void> run(String name, Map<String, Object?> args) =>
          context.resolve({'call': name, 'args': args}).first;
      await run('setValue', {'path': '/tab', 'value': 'orders'});
      await run('toggle', {'path': '/alerts'});
      await run('increment', {'path': '/qty', 'by': 5, 'max': 7});
      await run('increment', {'path': '/qty', 'by': 5, 'max': 7});
      await run('append', {'path': '/list', 'value': 'a'});
      await run('append', {'path': '/list', 'value': 'b'});
      await run('removeAt', {'path': '/list', 'index': 0});
      expect(model.getValue<Object?>(DataPath.root), {
        'tab': 'orders',
        'alerts': true,
        'qty': 7,
        'list': ['b'],
      });
    });
  });
}
