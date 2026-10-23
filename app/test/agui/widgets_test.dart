// Catalog components: inputs bound to the data model,
// client-side functions changing the UI without a round trip, conditional
// rendering, navigation and feedback, and the market components.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/agui/agui.dart';

import 'support.dart';

Future<AgUiSurfaces> pump(WidgetTester tester,
    List<Map<String, dynamic>> components,
    {Map<String, dynamic>? data,
    List<AgUiAction>? actions,
    bool settle = true}) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final surfaces = AgUiSurfaces()..ingest(surface(components, data));
  addTearDown(surfaces.dispose);
  await tester.pumpWidget(host(AgUiSurfaceView(
      surfaces: surfaces, surfaceId: 's', onAction: actions?.add)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
  return surfaces;
}

Map<String, dynamic> text(String id, Object? text) =>
    {'id': id, 'component': 'Text', 'text': text};

void main() {
  testWidgets('every new component renders', (tester) async {
    await pump(
        tester,
        [
          {
            'id': 'root',
            'component': 'Column',
            'children': [
              'seg', 'drop', 'range', 'step', 'search', 'link', 'ib', //
              'menu', 'steps', 'carousel', 'acc', 'empty', 'skeleton',
              'loading', 'tip', 'group', 'md', 'show', 'countdown', 'quote',
              'book', 'tape', 'alloc', 'trend',
            ]
          },
          {
            'id': 'seg',
            'component': 'SegmentedControl',
            'options': [
              {'label': '1D', 'value': '1d'},
              {'label': '1W', 'value': '1w'}
            ],
            'value': {'path': '/period'}
          },
          {
            'id': 'drop',
            'component': 'Dropdown',
            'label': 'Exchange',
            'options': ['NYSE', 'NASDAQ'],
            'value': {'path': '/exchange'}
          },
          {
            'id': 'range',
            'component': 'RangeSlider',
            'label': 'Price',
            'min': 0,
            'max': 500,
            'value': {'path': '/range'}
          },
          {
            'id': 'step',
            'component': 'NumberStepper',
            'label': 'Quantity',
            'value': {'path': '/qty'}
          },
          {
            'id': 'search',
            'component': 'SearchField',
            'value': {'path': '/q'}
          },
          {
            'id': 'link',
            'component': 'Link',
            'text': 'Docs',
            'url': 'https://aseman.app'
          },
          {
            'id': 'ib',
            'component': 'IconButton',
            'icon': 'refresh',
            'tooltip': 'Refresh',
            'action': {
              'event': {'name': 'refresh'}
            }
          },
          {
            'id': 'menu',
            'component': 'Menu',
            'items': [
              {
                'label': 'Export',
                'icon': 'download',
                'action': {
                  'event': {'name': 'export'}
                }
              }
            ]
          },
          {
            'id': 'steps',
            'component': 'Steps',
            'current': 1,
            'steps': [
              {'title': 'Placed'},
              {'title': 'Filled'},
              {'title': 'Settled'}
            ]
          },
          {
            'id': 'carousel',
            'component': 'Carousel',
            'height': 80,
            'children': ['c1', 'c2']
          },
          text('c1', 'Slide one'),
          text('c2', 'Slide two'),
          {
            'id': 'acc',
            'component': 'Accordion',
            'items': [
              {'title': 'What is a limit order?', 'child': 'a1'}
            ]
          },
          text('a1', 'An order at a price or better.'),
          {
            'id': 'empty',
            'component': 'EmptyState',
            'title': 'No positions',
            'text': 'Open a trade to see it here.'
          },
          {'id': 'skeleton', 'component': 'Skeleton', 'variant': 'lines'},
          {'id': 'loading', 'component': 'Loading', 'text': 'Syncing'},
          {
            'id': 'tip',
            'component': 'Tooltip',
            'message': 'Annualized',
            'child': 'tipText'
          },
          text('tipText', 'APY'),
          {
            'id': 'group',
            'component': 'AvatarGroup',
            'people': ['Ada', 'Grace', 'Linus'],
            'max': 2
          },
          {
            'id': 'md',
            'component': 'Markdown',
            'text': '## Notes\n\n- one\n- two'
          },
          {'id': 'show', 'component': 'Show', 'when': true, 'child': 'shown'},
          text('shown', 'Visible'),
          {
            'id': 'countdown',
            'component': 'Countdown',
            'label': 'Market closes in',
            'target': DateTime.now()
                .add(const Duration(hours: 2))
                .toIso8601String()
          },
          {
            'id': 'quote',
            'component': 'Quote',
            'symbol': 'AAPL',
            'name': 'Apple',
            'price': 189.5,
            'change': 0.012,
            'currency': 'USD',
            'trend': [1, 2, 3, 2, 4]
          },
          {
            'id': 'book',
            'component': 'OrderBook',
            'bids': [
              {'price': 99.5, 'size': 10},
              {'price': 99, 'size': 30}
            ],
            'asks': [
              [100.5, 5],
              [101, 20]
            ]
          },
          {
            'id': 'tape',
            'component': 'TickerTape',
            'speed': 0,
            'data': [
              {'symbol': 'BTC', 'price': 65000, 'change': -0.01}
            ]
          },
          {
            'id': 'alloc',
            'component': 'AllocationBar',
            'data': [
              {'label': 'Stocks', 'value': 60},
              {'label': 'Bonds', 'value': 40}
            ]
          },
          {'id': 'trend', 'component': 'Trend', 'value': -0.034},
        ],
        settle: false);
    for (final t in [
      '1D', 'Exchange', 'Quantity', 'Docs', 'Placed', 'Slide one', //
      'What is a limit order?', 'No positions', 'Syncing', 'APY', 'Visible',
      'Market closes in', 'AAPL', 'Spread 1.00 (1.000%)', 'BTC', 'Stocks',
      '60.0%', '+1',
    ]) {
      expect(find.textContaining(t, findRichText: true), findsWidgets,
          reason: t);
    }
    expect(find.text(r'$189.50'), findsOneWidget);
    expect(find.text('-3.40%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inputs write their bindings and fire their actions',
      (tester) async {
    final actions = <AgUiAction>[];
    final surfaces = await pump(
        tester,
        [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['seg', 'step', 'search']
          },
          {
            'id': 'seg',
            'component': 'SegmentedControl',
            'options': [
              {'label': 'Buy', 'value': 'buy'},
              {'label': 'Sell', 'value': 'sell'}
            ],
            'value': {'path': '/side'},
            'action': {
              'event': {'name': 'side'}
            }
          },
          {
            'id': 'step',
            'component': 'NumberStepper',
            'value': {'path': '/qty'},
            'min': 1,
            'max': 3,
          },
          {
            'id': 'search',
            'component': 'SearchField',
            'value': {'path': '/q'},
            'action': {
              'event': {'name': 'search'}
            }
          },
        ],
        data: {'side': 'buy', 'qty': 2},
        actions: actions);
    await tester.tap(find.text('Sell'));
    await tester.pumpAndSettle();
    expect(surfaces.dataModel('s')!.toString(), contains('side: sell'));
    expect(actions.single.name, 'side');
    expect(actions.single.context, {'value': 'sell'});

    await tester.tap(find.byTooltip('Increase'));
    await tester.pumpAndSettle();
    expect((surfaces.dataModel('s')! as Map)['qty'], 3);
    final increase = tester.widget<IconButton>(
        find.ancestor(of: find.byTooltip('Increase'), matching: find.byType(IconButton)));
    expect(increase.onPressed, isNull, reason: 'at max');

    await tester.enterText(find.byType(TextField), 'nvda');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect((surfaces.dataModel('s')! as Map)['q'], 'nvda');
    expect(actions.last.name, 'search');
    expect(actions.last.context, {'value': 'nvda'});
  });

  testWidgets('client functions change the UI without a round trip; Show '
      'follows the data', (tester) async {
    final actions = <AgUiAction>[];
    final surfaces = await pump(
        tester,
        [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['toggle', 'details', 'count', 'plus']
          },
          {
            'id': 'toggle',
            'component': 'Button',
            'child': 'toggleLabel',
            'action': {
              'functionCall': {
                'call': 'toggle',
                'args': {'path': '/open'}
              }
            }
          },
          text('toggleLabel', 'Details'),
          {
            'id': 'details',
            'component': 'Show',
            'when': {'path': '/open'},
            'child': 'body',
            'fallback': 'hint'
          },
          text('body', 'All the details'),
          text('hint', 'Tap Details'),
          text('count', {
            'call': 'formatString',
            'args': {'value': r'Count: ${/n}'}
          }),
          {
            'id': 'plus',
            'component': 'Button',
            'child': 'plusLabel',
            'action': {
              'functionCall': {
                'call': 'increment',
                'args': {'path': '/n'}
              }
            }
          },
          text('plusLabel', 'Add'),
        ],
        data: {'open': false, 'n': 0},
        actions: actions);
    expect(find.text('Tap Details'), findsOneWidget);
    expect(find.text('All the details'), findsNothing);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('All the details'), findsOneWidget);
    expect(find.text('Tap Details'), findsNothing);
    await tester.tap(find.text('Add'));
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Count: 2'), findsOneWidget);
    expect(actions, isEmpty, reason: 'nothing went to the backend');
    expect(surfaces.dataModel('s'), {'open': true, 'n': 2});
  });

  testWidgets('containers repeat a template for every item of a list',
      (tester) async {
    await pump(
        tester,
        [
          {
            'id': 'root',
            'component': 'Grid',
            'minColumnWidth': 150,
            'children': {'componentId': 'tile', 'path': '/quotes'}
          },
          {
            'id': 'tile',
            'component': 'Quote',
            'symbol': {'path': 'symbol'},
            'price': {'path': 'price'},
          },
        ],
        data: {
          'quotes': [
            {'symbol': 'AAPL', 'price': 1},
            {'symbol': 'MSFT', 'price': 2},
            {'symbol': 'NVDA', 'price': 3},
          ]
        });
    for (final s in ['AAPL', 'MSFT', 'NVDA']) {
      expect(find.text(s), findsOneWidget);
    }
  });

  testWidgets('order book rows and quotes fire their actions',
      (tester) async {
    final actions = <AgUiAction>[];
    await pump(
        tester,
        [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['book', 'quote']
          },
          {
            'id': 'book',
            'component': 'OrderBook',
            'bids': [
              {'price': 10, 'size': 1}
            ],
            'asks': [
              {'price': 11, 'size': 2}
            ],
            'action': {
              'event': {'name': 'fill'}
            }
          },
          {
            'id': 'quote',
            'component': 'Quote',
            'symbol': 'ETH',
            'price': {'path': '/eth'},
            'action': {
              'event': {
                'name': 'open',
                'context': {'symbol': 'ETH'}
              }
            }
          },
        ],
        data: {'eth': 3000},
        actions: actions);
    await tester.tap(find.text('11.00'));
    await tester.pumpAndSettle();
    expect(actions.single.name, 'fill');
    expect(actions.single.context, {'side': 'ask', 'price': 11, 'size': 2});
    await tester.tap(find.text('ETH'));
    await tester.pumpAndSettle();
    expect(actions.last.context, {'symbol': 'ETH'});
  });

  testWidgets('Accordion opens one section at a time', (tester) async {
    await pump(tester, [
      {
        'id': 'root',
        'component': 'Accordion',
        'items': [
          {'title': 'First', 'child': 'a'},
          {'title': 'Second', 'child': 'b'},
        ]
      },
      text('a', 'Alpha'),
      text('b', 'Beta'),
    ]);
    expect(find.text('Alpha'), findsNothing);
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
  });

  testWidgets('a Menu entry fires its action', (tester) async {
    final actions = <AgUiAction>[];
    await pump(
        tester,
        [
          {
            'id': 'root',
            'component': 'Menu',
            'items': [
              {
                'label': 'Close position',
                'destructive': true,
                'action': {
                  'event': {'name': 'close'}
                }
              }
            ]
          },
        ],
        actions: actions);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close position'));
    await tester.pumpAndSettle();
    expect(actions.single.name, 'close');
  });
}
