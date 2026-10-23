// Generated surfaces laid out as app screens: they fill their window, their
// regions scroll inside themselves, and a Split is panes side by side on a
// desktop and tabs on a phone.
import 'package:aseman/src/agui/agui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The messages of an app-layout surface.
List<Map<String, dynamic>> app(List<Map<String, dynamic>> components,
        [Map<String, dynamic>? data]) =>
    [
      {
        'version': 'v0.9',
        'createSurface': {
          'surfaceId': 's',
          'catalogId': asemanCatalogId,
          'theme': {'layout': 'app'}
        }
      },
      {
        'version': 'v0.9',
        'updateComponents': {'surfaceId': 's', 'components': components}
      },
      if (data != null)
        {
          'version': 'v0.9',
          'updateDataModel': {'surfaceId': 's', 'path': '/', 'value': data}
        },
    ];

Map<String, dynamic> text(String id, Object? text) =>
    {'id': id, 'component': 'Text', 'text': text};

/// [messages] in a window of [size], as the desk shows a frontend.
Future<void> pumpWindow(WidgetTester tester, Size size,
    List<Map<String, dynamic>> messages) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AgUiFrame(messages: messages, child: AgUiView(messages: messages)),
    ),
  ));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

final rows = {
  'rows': [
    for (var i = 0; i < 60; i++) {'name': 'Row $i'}
  ]
};

final screen = [
  {
    'id': 'root',
    'component': 'Column',
    'children': ['title', 'body']
  },
  text('title', 'Orders'),
  {'id': 'body', 'component': 'Scroll', 'weight': 1, 'children': ['list']},
  {
    'id': 'list',
    'component': 'List',
    'children': {'componentId': 'row', 'path': '/rows'}
  },
  text('row', {'path': 'name'}),
];

void main() {
  testWidgets('an app screen fits its window and scrolls only its body',
      (tester) async {
    await pumpWindow(tester, const Size(360, 640), app(screen, rows));
    final title = tester.getTopLeft(find.text('Orders'));
    // The surface is the window's height, not its content's.
    expect(tester.getSize(find.byType(AgUiSurfaceView)).height,
        lessThanOrEqualTo(640));
    // The last row is below the window until the body is scrolled to it.
    expect(tester.getTopLeft(find.text('Row 59')).dy, greaterThan(640));
    await tester.dragUntilVisible(
        find.text('Row 59'), find.byType(SingleChildScrollView).last,
        const Offset(0, -300));
    expect(tester.getBottomLeft(find.text('Row 59')).dy, lessThanOrEqualTo(640));
    // The header stayed where it was: only the body scrolled.
    expect(tester.getTopLeft(find.text('Orders')), title);
  });

  testWidgets('a surface made as a page still scrolls as a whole',
      (tester) async {
    final page = app(screen, rows)
      ..first = {
        'version': 'v0.9',
        'createSurface': {'surfaceId': 's', 'catalogId': asemanCatalogId}
      };
    expect(isAppLayout(page), isFalse);
    await pumpWindow(tester, const Size(360, 640), [
      page.first,
      {
        'version': 'v0.9',
        'updateComponents': {
          'surfaceId': 's',
          'components': [
            {
              'id': 'root',
              'component': 'Column',
              'children': ['title', 'list']
            },
            text('title', 'Orders'),
            screen[3],
            screen[4],
          ]
        }
      },
      page.last,
    ]);
    expect(tester.getSize(find.byType(AgUiSurfaceView)).height,
        greaterThan(640));
  });

  final split = [
    {
      'id': 'root',
      'component': 'Column',
      'children': ['title', 'split']
    },
    text('title', 'Traders'),
    {
      'id': 'split',
      'component': 'Split',
      'weight': 1,
      'panes': [
        {'title': 'List', 'child': 'list'},
        {'title': 'Details', 'child': 'details'},
      ]
    },
    {
      'id': 'list',
      'component': 'List',
      'children': {'componentId': 'row', 'path': '/rows'}
    },
    text('row', {'path': 'name'}),
    text('details', 'Pick a trader'),
  ];

  testWidgets('a Split is panes side by side on a desktop', (tester) async {
    await pumpWindow(tester, const Size(1400, 900), app(split, rows));
    expect(find.text('Row 0'), findsOneWidget);
    expect(find.text('Pick a trader'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Pick a trader')).dx,
        greaterThan(tester.getTopLeft(find.text('Row 0')).dx));
    // Each pane scrolls by itself.
    await tester.dragUntilVisible(find.text('Row 59'),
        find.byType(SingleChildScrollView).first, const Offset(0, -300));
    expect(find.text('Pick a trader'), findsOneWidget);
  });

  testWidgets('a Split is tabs on a phone', (tester) async {
    await pumpWindow(tester, const Size(360, 640), app(split, rows));
    expect(find.text('Row 0'), findsOneWidget);
    expect(find.text('Pick a trader'), findsNothing);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a trader'), findsOneWidget);
    expect(find.text('Row 0'), findsNothing);
  });

  testWidgets('a Tabs given the body fills it and scrolls each tab',
      (tester) async {
    await pumpWindow(
        tester,
        const Size(360, 640),
        app([
          {
            'id': 'root',
            'component': 'Column',
            'children': ['title', 'tabs']
          },
          text('title', 'Orders'),
          {
            'id': 'tabs',
            'component': 'Tabs',
            'weight': 1,
            'tabs': [
              {'title': 'Open', 'child': 'list'},
              {'title': 'Done', 'child': 'done'},
            ]
          },
          screen[3],
          screen[4],
          text('done', 'Nothing done yet'),
        ], rows));
    final title = tester.getTopLeft(find.text('Orders'));
    await tester.dragUntilVisible(find.text('Row 59'),
        find.byType(SingleChildScrollView).last, const Offset(0, -300));
    expect(tester.getTopLeft(find.text('Orders')), title);
  });
}
