import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/elpian/elpian.dart';
import 'package:tradera/src/features/tools/presentation/a2ui_view.dart';
import 'package:tradera/src/features/tools/ui_kit/kit.dart';

const _catalog = 'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json';

List<Map<String, dynamic>> surface(
        List<Map<String, dynamic>> components, Map<String, dynamic> data) =>
    [
      {
        'version': 'v0.9',
        'createSurface': {'surfaceId': 's', 'catalogId': _catalog}
      },
      {
        'version': 'v0.9',
        'updateComponents': {'surfaceId': 's', 'components': components}
      },
      {
        'version': 'v0.9',
        'updateDataModel': {'surfaceId': 's', 'path': '/', 'value': data}
      },
    ];

final _quotes = [
  {'symbol': 'AAPL', 'name': 'Apple', 'price': 227.5, 'change': 0.0123, 'volume': 51200000, 'trend': [1, 3, 2, 5, 4]},
  {'symbol': 'MSFT', 'name': 'Microsoft', 'price': 415.1, 'change': -0.0071, 'volume': 20100000, 'trend': [5, 4, 4, 3, 2]},
  {'symbol': 'NVDA', 'name': 'Nvidia', 'price': 121.3, 'change': 0.0412, 'volume': 300400000, 'trend': [1, 2, 4, 6, 9]},
];

final _dashboard = surface([
  {'id': 'root', 'component': 'Column', 'children': ['stats', 'charts', 'table', 'picked', 'more']},
  {'id': 'stats', 'component': 'Grid', 'minColumnWidth': 160, 'children': ['s1', 's2']},
  {'id': 's1', 'component': 'Stat', 'label': 'Portfolio', 'value': {'path': '/total'}, 'format': 'currency:USD', 'delta': 0.034, 'deltaFormat': '+percent:1', 'deltaLabel': 'vs last week', 'trend': [3, 4, 3, 5, 6]},
  {'id': 's2', 'component': 'Stat', 'label': 'Open orders', 'value': 12, 'icon': 'trendingUp'},
  {'id': 'charts', 'component': 'Grid', 'columns': 2, 'children': ['line', 'bars', 'pie', 'candles']},
  {'id': 'line', 'component': 'Chart', 'type': 'area', 'title': 'Equity', 'data': {'path': '/history'}, 'x': 'day', 'series': [{'field': 'value', 'label': 'Equity'}], 'yFormat': 'compact'},
  {'id': 'bars', 'component': 'Chart', 'type': 'bar', 'stacked': true, 'data': {'path': '/history'}, 'x': 'day', 'series': ['buys', 'sells']},
  {'id': 'pie', 'component': 'Chart', 'type': 'donut', 'data': {'path': '/allocation'}, 'label': 'asset', 'value': 'weight', 'format': 'percent'},
  {'id': 'candles', 'component': 'Chart', 'type': 'candlestick', 'data': {'path': '/ohlc'}, 'x': 'day'},
  {'id': 'table', 'component': 'Table', 'data': {'path': '/quotes'}, 'selection': {'path': '/selected'}, 'action': {'event': {'name': 'open', 'context': {'symbol': {'path': 'symbol'}}}}, 'columns': [
    {'field': 'symbol', 'label': 'Symbol'},
    {'field': 'price', 'type': 'number', 'format': 'currency'},
    {'field': 'change', 'type': 'trend', 'format': 'percent:2'},
    {'field': 'volume', 'type': 'number', 'format': 'compact'},
    {'field': 'trend', 'type': 'sparkline'},
  ]},
  {'id': 'picked', 'component': 'Text', 'text': {'call': 'formatString', 'args': {'value': r'Selected: ${/selected/name}'}, 'returnType': 'string'}},
  {'id': 'more', 'component': 'Section', 'title': 'More', 'children': ['heat', 'tree', 'graph', 'kv', 'gauge', 'badge', 'progress', 'timeline', 'json', 'code', 'callout', 'box', 'toggle', 'raw', 'expand', 'treeview', 'rating', 'spark', 'radar', 'scatter', 'hist']},
  {'id': 'heat', 'component': 'Heatmap', 'data': [{'x': 'Mon', 'y': 'AM', 'value': 1}, {'x': 'Tue', 'y': 'PM', 'value': -2}], 'showValues': true},
  {'id': 'tree', 'component': 'Treemap', 'data': {'path': '/quotes'}, 'label': 'symbol', 'value': 'volume', 'colorBy': 'change', 'colorFormat': '+percent:1'},
  {'id': 'graph', 'component': 'Graph', 'nodes': [{'id': 'a', 'group': 'x'}, {'id': 'b', 'group': 'y'}], 'edges': [{'from': 'a', 'to': 'b', 'label': 'feeds'}], 'height': 200},
  {'id': 'kv', 'component': 'KeyValue', 'items': [{'label': 'Exchange', 'value': 'NASDAQ'}, {'label': 'Change', 'value': 0.02, 'type': 'trend', 'format': 'percent:1'}]},
  {'id': 'gauge', 'component': 'Gauge', 'value': 72, 'label': 'Risk', 'thresholds': [{'value': 60, 'status': 'warning'}]},
  {'id': 'badge', 'component': 'Badge', 'text': 'Live', 'status': 'good'},
  {'id': 'progress', 'component': 'Progress', 'value': 0.4, 'label': 'Synced'},
  {'id': 'timeline', 'component': 'Timeline', 'data': [{'title': 'Order filled', 'time': '2026-10-01T10:00:00', 'status': 'good'}], 'timeFormat': 'datetime'},
  {'id': 'json', 'component': 'JsonView', 'value': {'path': '/quotes/0'}},
  {'id': 'code', 'component': 'CodeBlock', 'code': 'print(1)', 'language': 'python'},
  {'id': 'callout', 'component': 'Callout', 'severity': 'warning', 'title': 'Heads up', 'text': 'Market closes soon'},
  {'id': 'box', 'component': 'Box', 'padding': 12, 'color': 'surfaceVariant', 'borderRadius': 12, 'child': 'boxText'},
  {'id': 'boxText', 'component': 'Text', 'text': 'In a box'},
  {'id': 'toggle', 'component': 'Switch', 'label': 'Alerts', 'value': {'path': '/alerts'}},
  {'id': 'raw', 'component': 'Elpian', 'node': {'type': 'Padding', 'props': {'style': {'padding': 4}}, 'children': [{'slot': 'rawText'}]}},
  {'id': 'rawText', 'component': 'Text', 'text': {'path': '/total'}},
  {'id': 'expand', 'component': 'Expandable', 'title': 'Details', 'children': ['hidden']},
  {'id': 'hidden', 'component': 'Text', 'text': 'Hidden details'},
  {'id': 'treeview', 'component': 'TreeView', 'data': {'label': 'Root', 'children': [{'label': 'Leaf', 'value': 3}]}},
  {'id': 'rating', 'component': 'Rating', 'value': 3.5},
  {'id': 'spark', 'component': 'Sparkline', 'values': [1, 2, 3]},
  {'id': 'radar', 'component': 'Chart', 'type': 'radar', 'data': [{'label': 'A', 'v': 1}, {'label': 'B', 'v': 2}, {'label': 'C', 'v': 3}], 'series': ['v']},
  {'id': 'scatter', 'component': 'Chart', 'type': 'bubble', 'data': {'path': '/quotes'}, 'x': 'price', 'y': 'change', 'size': 'volume'},
  {'id': 'hist', 'component': 'Chart', 'type': 'histogram', 'data': [1, 2, 2, 3, 3, 3, 4, 9]},
], {
  'total': 15234.5,
  'alerts': false,
  'history': [
    {'day': 'Mon', 'value': 12000, 'buys': 3, 'sells': 1},
    {'day': 'Tue', 'value': 12800, 'buys': 2, 'sells': 2},
    {'day': 'Wed', 'value': 12500, 'buys': 4, 'sells': 0},
  ],
  'allocation': [
    {'asset': 'Stocks', 'weight': 0.6},
    {'asset': 'Bonds', 'weight': 0.3},
    {'asset': 'Cash', 'weight': 0.1},
  ],
  'ohlc': [
    {'day': 'Mon', 'open': 10, 'high': 12, 'low': 9, 'close': 11},
    {'day': 'Tue', 'open': 11, 'high': 11.5, 'low': 8, 'close': 9},
  ],
  'quotes': _quotes,
});

void main() {
  group('formats', () {
    test('numbers, compact, percent, currency, signs, dates', () {
      expect(formatValue(1234.5, 'number:1'), '1,234.5');
      expect(formatValue(12900, 'compact'), '12.9K');
      expect(formatValue(0.1234, 'percent:1'), '12.3%');
      expect(formatValue(-5.5, 'currency:EUR'), '-€5.50');
      expect(formatValue(0.05, '+percent'), '+5%');
      expect(formatValue('2026-01-02T03:04:00', 'date'), 'Jan 2, 2026');
      expect(formatValue('n/a', 'number'), 'n/a');
    });

    test('axis ticks are round and cover the range', () {
      final ticks = niceTicks(3, 97);
      expect(ticks.first, lessThanOrEqualTo(3));
      expect(ticks.last, greaterThanOrEqualTo(97));
      expect(ticks, contains(50));
    });
  });

  group('generative frontends', () {
    testWidgets('render every Tradera component, bound to data', (tester) async {
      tester.view.physicalSize = const Size(1200, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final actions = <(String, Map<String, dynamic>)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: A2UIView(
              messages: _dashboard,
              onAction: (a, data) async {
                actions.add((a.name, a.context));
                return null;
              },
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Unknown'), findsNothing);
      expect(find.textContaining('Expected'), findsNothing);
      // Stat tile with a bound, formatted value and a signed delta.
      expect(find.text(r'$15,234.50'), findsOneWidget);
      expect(find.text('+3.4% vs last week'), findsNothing);
      expect(find.text('+3.4%'), findsOneWidget);
      // The table: formatted cells.
      expect(find.text('AAPL'), findsWidgets);
      expect(find.text('+4.12%'), findsOneWidget);
      expect(find.text('300.4M'), findsOneWidget);
      // Raw Elpian node with an A2UI slot inside.
      expect(find.text('15234.5'), findsOneWidget);
      // Tapping a row writes the selection and fires the action in its scope.
      await tester.tap(find.text('MSFT').first);
      await tester.pumpAndSettle();
      expect(find.text('Selected: Microsoft'), findsOneWidget);
      expect(actions.single.$1, 'open');
      expect(actions.single.$2, {'symbol': 'MSFT'});
      // Expandable reveals its children.
      expect(find.text('Hidden details'), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('Hidden details'), findsOneWidget);
      // A Switch writes its binding.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('sorting a table by a column', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: A2UIView(
              messages: surface([
            {'id': 'root', 'component': 'Table', 'data': {'path': '/q'}, 'columns': ['symbol', {'field': 'price', 'type': 'number'}]},
          ], {
            'q': _quotes
          })),
        ),
      ));
      await tester.pumpAndSettle();
      double y(String s) => tester.getTopLeft(find.text(s)).dy;
      expect(y('AAPL') < y('MSFT') && y('MSFT') < y('NVDA'), isTrue);
      await tester.tap(find.text('Price'));
      await tester.pumpAndSettle(); // numbers sort high → low first
      expect(y('MSFT') < y('AAPL') && y('AAPL') < y('NVDA'), isTrue);
    });
  });

  group('static frontends', () {
    testWidgets('kit nodes render in the engine and send select events',
        (tester) async {
      final engine = kitEngine();
      final selected = <Map<String, dynamic>>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (_) => engine.renderFromJson({
              'type': 'Column',
              'children': [
                {
                  'type': 'Chart',
                  'key': 'chart',
                  'props': {
                    'type': 'bar',
                    'data': [
                      {'label': 'A', 'value': 3},
                      {'label': 'B', 'value': 5},
                    ],
                    'height': 200,
                  },
                  'events': {
                    'select': (ElpianEvent e) => selected.add(e.data),
                  },
                },
                {
                  'type': 'Stat',
                  'props': {'label': 'Users', 'value': 1284000},
                },
              ],
            }),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('1.3M'), findsOneWidget);
      final chart = tester.getRect(find.byType(CartesianChart));
      // The second bar sits in the right half of the plot.
      await tester.tapAt(Offset(chart.left + chart.width * 0.75, chart.bottom - 40));
      await tester.pumpAndSettle();
      expect(selected.single['row'], {'label': 'B', 'value': 5});
      expect(tester.takeException(), isNull);
    });
  });
}
