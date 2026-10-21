// Frontends as compact phone widgets: an A2UI surface's own `compact`
// component, or a summary derived from its components; static programs'
// published summaries.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart'
    show Component, SurfaceDefinition, basicCatalogId;
import 'package:aseman/src/features/tools/data/tools_api.dart';
import 'package:aseman/src/features/tools/runtime/tool_frontend_host.dart';
import 'package:aseman/src/genui/genui.dart';

import 'support.dart';

Future<void> pumpAs(WidgetTester tester, FrontendDisplay display,
    List<Map<String, dynamic>> messages,
    {ValueChanged<CompactHint>? onHint, String size = 'medium'}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 340,
          height: 170,
          child: FrontendPresentation(
            display: display,
            size: size,
            onHint: onHint,
            // In full, frontends scroll (as ToolFrontendView does).
            child: display == FrontendDisplay.compact
                ? GenUiView(messages: messages)
                : SingleChildScrollView(child: GenUiView(messages: messages)),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

final _dashboard = [
  {'id': 'root', 'component': 'Column', 'children': ['title', 'kpis', 'chart']},
  {'id': 'title', 'component': 'Text', 'text': 'Portfolio', 'variant': 'h4'},
  {'id': 'kpis', 'component': 'Grid', 'children': ['total', 'pnl']},
  {
    'id': 'total',
    'component': 'Stat',
    'label': 'Total value',
    'value': {'path': '/total'},
    'format': 'currency:USD',
    'delta': {'path': '/change'},
    'deltaFormat': '+percent:1',
  },
  {
    'id': 'pnl',
    'component': 'Stat',
    'label': 'Today',
    'value': {'path': '/pnl'},
    'format': '+currency:USD',
  },
  {
    'id': 'chart',
    'component': 'Chart',
    'type': 'area',
    'data': {'path': '/history'},
    'x': 'day',
    'y': 'value',
  },
];

const _data = {
  'total': 15234.5,
  'change': 0.034,
  'pnl': 120,
  'history': [
    {'day': 'Mon', 'value': 1},
    {'day': 'Tue', 'value': 3},
    {'day': 'Wed', 'value': 2},
  ],
};

void main() {
  testWidgets('a surface without a compact component is summed up from its '
      'components', (tester) async {
    await pumpAs(tester, FrontendDisplay.compact, surface(_dashboard, _data));
    expect(find.text('TOTAL VALUE'), findsOneWidget);
    expect(find.text(r'$15,234.50'), findsOneWidget);
    expect(find.text('+3.4%'), findsOneWidget);
    // The second KPI as a metric; the chart's trend as a sparkline.
    expect(find.text('Today'), findsOneWidget);
    expect(find.text(r'+$120.00'), findsOneWidget);
    // Nothing of the full surface: no chart frame, no grid.
    expect(find.text('Portfolio'), findsNothing);

    // In full (and in a sheet), the whole surface.
    await pumpAs(tester, FrontendDisplay.sheet, surface(_dashboard, _data));
    expect(find.text('Portfolio'), findsOneWidget);
  });

  testWidgets('a surface\'s own compact component is its widget, live on '
      'the same data', (tester) async {
    final hints = <CompactHint>[];
    final messages = [
      {
        'version': 'v0.9',
        'createSurface': {
          'surfaceId': 's',
          'catalogId': basicCatalogId,
          'theme': {'compactShape': 'circle', 'compactSize': 'small'},
        }
      },
      {
        'version': 'v0.9',
        'updateComponents': {
          'surfaceId': 's',
          'components': [
            ..._dashboard,
            {
              'id': 'compact',
              'component': 'Text',
              'text': {
                'call': 'formatString',
                'args': {'value': r'Up ${/pnl} today'}
              }
            },
          ]
        }
      },
      {
        'version': 'v0.9',
        'updateDataModel': {'surfaceId': 's', 'path': '/', 'value': _data}
      },
    ];
    await pumpAs(tester, FrontendDisplay.compact, messages, onHint: hints.add);
    expect(find.text('Up 120 today'), findsOneWidget);
    expect(find.text('Total value'), findsNothing);
    expect(hints.last, const CompactHint(shape: 'circle', size: 'small'));
  });

  test('summaries are derived from quotes, gauges, charts and lists', () {
    SurfaceDefinition def(List<Map<String, dynamic>> components) =>
        SurfaceDefinition(surfaceId: 's', components: {
          for (final c in components) c['id'] as String: Component.fromJson(c)
        });
    final quote = deriveCompactSpec(def([
      {'id': 'root', 'component': 'Column', 'children': ['q']},
      {
        'id': 'q',
        'component': 'Quote',
        'symbol': 'AAPL',
        'price': {'path': '/p'},
        'currency': 'USD',
        'change': 0.01
      },
    ]));
    final hero = quote['hero'] as Map;
    expect(hero['label'], 'AAPL');
    expect(hero['value'], {'path': '/p'});
    expect(hero['format'], 'currency:USD');
    final gauge = deriveCompactSpec(def([
      {'id': 'root', 'component': 'Gauge', 'value': 72, 'label': 'Risk'},
    ]));
    expect((gauge['hero'] as Map)['progress'],
        {'value': 72, 'min': 0, 'max': 100});
    final chart = deriveCompactSpec(def([
      {
        'id': 'root',
        'component': 'Chart',
        'title': 'BTC',
        'type': 'candlestick',
        'data': {'path': '/ohlc'},
      },
    ]));
    expect((chart['chart'] as Map)['field'], 'close');
    expect((chart['chart'] as Map)['rows'], {'path': '/ohlc'});
    expect(chart['title'], 'BTC');
    // A template is an item's scope: it shapes the list, not the hero.
    final list = deriveCompactSpec(def([
      {
        'id': 'root',
        'component': 'List',
        'children': {'componentId': 'row', 'path': '/rows'}
      },
      {
        'id': 'row',
        'component': 'Stat',
        'label': {'path': 'name'},
        'value': {'path': 'v'}
      },
    ]));
    expect(list.containsKey('hero'), isFalse);
    expect(list['list'],
        {'rows': {'path': '/rows'}, 'title': 'name', 'value': 'v'});
    // A table's columns name the row fields.
    final table = deriveCompactSpec(def([
      {
        'id': 'root',
        'component': 'Table',
        'data': {'path': '/t'},
        'columns': [
          {'field': 'sym'},
          {'field': 'px', 'type': 'number', 'format': 'currency'},
          {'field': 'chg', 'type': 'trend'},
        ]
      },
    ]));
    expect((table['list'] as Map)['title'], 'sym');
    expect((table['list'] as Map)['value'], 'px');
    expect((table['list'] as Map)['delta'], 'chg');
  });

  test('summary JSON: hero, chart, list, metrics, chips and the data model',
      () {
    final s = CompactSummary.fromJson({
      'title': 'BTC',
      'value': 65000,
      'trend': {
        'rows': [
          {'close': 1},
          {'close': 2}
        ],
        'field': 'close'
      },
      'progress': {'value': 30, 'max': 60},
      'metrics': [
        {'label': 'Vol', 'value': 3}
      ],
      'chips': [
        {'text': 'Live', 'status': 'good'}
      ],
    });
    expect(s.hero!.shown, '65,000');
    expect(s.hero!.progress, .5);
    expect(s.chart!.values, [1, 2]);
    expect(s.metrics.single.label, 'Vol');
    expect(s.chips.single.text, 'Live');

    final list = CompactSummary.fromJson({
      'list': {
        'rows': [
          {'symbol': 'AAPL', 'price': 190.5, 'change': 0.012},
          {'symbol': 'NVDA', 'price': 120, 'change': -0.02},
        ],
      },
    });
    expect(list.list!.rows.first.title, 'AAPL');
    expect(list.list!.total, 2);

    // Nothing said: the data model fills it in.
    final data = CompactSummary.fromJson({
      'data': {
        'balance': 1200,
        'fee': 3,
        'history': [1, 3, 2],
      },
    });
    expect(data.hero!.label, 'Balance');
    expect(data.metrics.single.label, 'Fee');
    expect(data.chart!.values, [1, 3, 2]);
    expect(data.richness, greaterThanOrEqualTo(2));
  });

  test('static programs publish their summary and see how they are shown',
      () async {
    Map<String, dynamic>? published;
    var expanded = false;
    final host = ToolFrontendHost(
        ToolsApi((ns, action, body, {timeout}) async => null),
        botId: 'bot',
        spaceId: 's1',
        display: 'compact',
        onCompact: (s) => published = s,
        onExpand: () => expanded = true);
    final handlers = host.handlers();
    final context = jsonDecode(await handlers['tool.context']!(
        'tool.context', '[]')) as Map;
    expect(context['data']['value']['display'], 'compact');
    await handlers['tool.compact']!(
        'tool.compact',
        jsonEncode([
          {'title': 'Balance', 'value': 12, 'shape': 'pill'}
        ]));
    expect(published, {'title': 'Balance', 'value': 12, 'shape': 'pill'});
    await handlers['tool.expand']!('tool.expand', '[]');
    expect(expanded, isTrue);
    final bad = jsonDecode(
        await handlers['tool.compact']!('tool.compact', '[]')) as Map;
    expect(jsonEncode(bad), contains('invalid_argument'));
  });
}
