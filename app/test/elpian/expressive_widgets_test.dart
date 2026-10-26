import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/elpian/elpian.dart';
import 'package:aseman/src/elpian/widgets/elpian_expressive.dart';
import 'package:aseman/src/elpian/widgets/elpian_icon.dart';
import 'package:aseman/src/elpian/widgets/elpian_material.dart';
import 'package:aseman/src/features/tools/ui_kit/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders [tree] with the kit engine in the app's theme.
Future<void> pumpTree(WidgetTester tester, Map<String, dynamic> tree,
    {ThemeData? theme}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final engine = kitEngine();
  await tester.pumpWidget(MaterialApp(
    theme: theme ?? AppTheme.light,
    home: Scaffold(
      body: SingleChildScrollView(
        child: Builder(builder: (_) => engine.renderFromJson(tree)),
      ),
    ),
  ));
  // Loading indicators and wavy bars animate forever: pump, not settle.
  await tester.pump(const Duration(milliseconds: 500));
}

Map<String, dynamic> gallery(void Function(String, ElpianEvent) on) => {
      'type': 'Column',
      'props': {
        'style': {'gap': '12', 'padding': '16'}
      },
      'children': [
        {
          'type': 'Text',
          'props': {'text': 'Display', 'variant': 'displaySmallEmphasized'}
        },
        {
          'type': 'Text',
          'props': {'text': 'Muted', 'variant': 'bodyMedium', 'color': 'muted'}
        },
        for (final v in ['filled', 'tonal', 'outlined', 'text', 'elevated', 'danger'])
          {
            'type': 'Button',
            'key': 'btn-$v',
            'props': {'text': v, 'variant': v, 'icon': 'add'},
            'events': {'tap': (ElpianEvent e) => on('btn-$v', e)},
          },
        {
          'type': 'Button',
          'props': {'text': 'Huge', 'size': 'xl', 'shape': 'square'}
        },
        {
          'type': 'Button',
          'props': {'text': 'Saving', 'loading': true}
        },
        {
          'type': 'IconButton',
          'key': 'fav',
          'props': {
            'icon': 'favorite_border',
            'selectedIcon': 'favorite',
            'selected': false,
            'variant': 'tonal'
          },
          'events': {'tap': (ElpianEvent e) => on('fav', e)},
        },
        {
          'type': 'SegmentedButton',
          'key': 'seg',
          'props': {
            'segments': [
              {'value': 'day', 'label': 'Day'},
              {'value': 'week', 'label': 'Week', 'icon': 'date_range'},
              'month',
            ],
            'selected': 'day',
          },
          'events': {'change': (ElpianEvent e) => on('seg', e)},
        },
        {
          'type': 'Chip',
          'key': 'chip',
          'props': {'label': 'Open', 'selected': false, 'icon': 'bolt'},
          'events': {'change': (ElpianEvent e) => on('chip', e)},
        },
        {
          'type': 'ListGroup',
          'props': {'title': 'Today'},
          'children': [
            {
              'type': 'ListTile',
              'key': 'tile',
              'props': {
                'title': 'Standup',
                'subtitle': '9:30 · Room 4',
                'leading': 'event',
                'trailingText': 'Now',
                'overline': 'Next'
              },
              'events': {'tap': (ElpianEvent e) => on('tile', e)},
            },
            {
              'type': 'ListTile',
              'props': {'title': 'Ann Lee', 'leadingAvatar': 'Ann Lee'}
            },
          ],
        },
        {
          'type': 'Card',
          'key': 'card',
          'props': {
            'variant': 'filled',
            'style': {'padding': '16', 'gap': '8'}
          },
          'events': {'tap': (ElpianEvent e) => on('card', e)},
          'children': [
            {
              'type': 'Text',
              'props': {'text': 'Card body'}
            },
            {
              'type': 'Badge',
              'props': {'count': 120},
              'children': [
                {
                  'type': 'Icon',
                  'props': {'icon': 'notifications'}
                }
              ]
            },
          ],
        },
        {
          'type': 'Card',
          'props': {'tone': 'primary'},
          'children': [
            {
              'type': 'Text',
              'props': {'text': 'Highlighted'}
            }
          ]
        },
        {
          'type': 'TextField',
          'props': {
            'label': 'Amount',
            'icon': 'payments',
            'prefix': r'$',
            'helper': 'Up to 500',
            'variant': 'outlined'
          }
        },
        {
          'type': 'SearchBar',
          'props': {'hint': 'Search orders'}
        },
        {
          'type': 'Switch',
          'props': {'value': true, 'label': 'Notifications'}
        },
        {
          'type': 'Checkbox',
          'props': {'value': false, 'label': 'Remember me'}
        },
        {
          'type': 'Slider',
          'props': {'value': 40, 'min': 0, 'max': 100, 'step': 10, 'label': '%'}
        },
        {
          'type': 'LoadingIndicator',
          'props': {'contained': true}
        },
        {
          'type': 'Stat',
          'props': {
            'label': 'Revenue',
            'value': 48210,
            'format': 'currency:USD:0',
            'delta': 0.12,
            'deltaFormat': '+percent',
            'deltaLabel': 'vs last week',
            'icon': 'payments',
            'trend': [3, 5, 4, 8, 9],
            'size': 'hero'
          }
        },
        {
          'type': 'Progress',
          'props': {'value': 0.62, 'label': 'Upload', 'wavy': true}
        },
        {
          'type': 'Progress',
          'props': {'value': 30, 'label': 'Plain'}
        },
        {
          'type': 'Tag',
          'props': {'text': 'Active', 'status': 'good'}
        },
        {
          'type': 'Callout',
          'props': {
            'title': 'Heads up',
            'text': 'Quota is at 80%',
            'severity': 'warning'
          }
        },
        {
          'type': 'Section',
          'props': {'title': 'Activity', 'subtitle': 'Last 7 days', 'icon': 'timeline'},
          'children': [
            {
              'type': 'Expandable',
              'props': {'title': 'Details', 'expanded': true},
              'children': [
                {
                  'type': 'Text',
                  'props': {'text': 'More'}
                }
              ]
            }
          ]
        },
        {
          'type': 'FAB',
          'props': {'icon': 'edit', 'label': 'Compose', 'variant': 'tertiary'}
        },
        {
          'type': 'NavigationBar',
          'key': 'nav',
          'props': {
            'items': [
              {'icon': 'home', 'label': 'Home'},
              {'icon': 'insights', 'label': 'Stats', 'badge': 3},
              {'icon': 'settings', 'label': 'Settings'},
            ],
            'selected': 0,
          },
          'events': {'change': (ElpianEvent e) => on('nav', e)},
        },
      ],
    };

void main() {
  for (final dark in [false, true]) {
    testWidgets('the M3 Expressive set renders (${dark ? 'dark' : 'light'})',
        (tester) async {
      await pumpTree(tester, gallery((_, __) {}),
          theme: dark ? AppTheme.dark : AppTheme.light);
      expect(tester.takeException(), isNull);
      expect(find.text('Display'), findsOneWidget);
      expect(find.byType(SegmentedButton<String>), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(ExpressiveLoadingIndicator), findsOneWidget);
      expect(find.byType(ExpressiveBar), findsNWidgets(2));
      expect(find.text(r'$48,210'), findsOneWidget);
      expect(find.text('99+'), findsOneWidget);
    });
  }

  testWidgets('controls report their events once', (tester) async {
    final got = <String, List<ElpianEvent>>{};
    await pumpTree(
        tester, gallery((k, e) => (got[k] ??= []).add(e)));

    await tester.tap(find.text('tonal'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(got['btn-tonal']?.length, 1);

    await tester.tap(find.text('Week'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(got['seg']?.single.data['value'], 'week');

    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(got['chip']?.single.data['value'], true);

    await tester.tap(find.text('Standup'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(got['tile']?.length, 1);

    await tester.tap(find.text('Card body'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(got['card']?.length, 1);

    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    await tester.pump(const Duration(milliseconds: 500));
    expect(got['fav']?.length, 1);

    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(got['nav']?.single.data['value'], 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a disabled button does not tap', (tester) async {
    var taps = 0;
    await pumpTree(tester, {
      'type': 'Button',
      'props': {'text': 'Off', 'disabled': true},
      'events': {'tap': (ElpianEvent e) => taps++},
    });
    await tester.tap(find.text('Off'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 0);
  });

  testWidgets('the primary class does not paint a filled label invisible',
      (tester) async {
    await pumpTree(tester, {
      'type': 'Button',
      'props': {'text': 'Go', 'className': 'primary'},
    }, theme: AppTheme.light);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.style?.foregroundColor, isNull);
  });

  test('icons are rounded and resolve in any case style', () {
    expect(ElpianIcon.iconData('home'), Icons.home_rounded);
    expect(ElpianIcon.iconData('trendingUp'), Icons.trending_up_rounded);
    expect(ElpianIcon.iconData('delete-outline'), Icons.delete_outline_rounded);
    expect(ElpianIcon.iconData('settings_rounded'), Icons.settings_rounded);
    expect(ElpianIcon.iconData('rocket_launch'), Icons.rocket_launch_rounded);
    expect(ElpianIcon.iconData('no_such_icon_name'), isNull);
  });

  testWidgets('type roles follow the theme and emphasize', (tester) async {
    late TextStyle? plain, bold, theme;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Builder(builder: (context) {
        theme = Theme.of(context).textTheme.titleMedium;
        plain = typeRole(context, 'titleMedium');
        bold = typeRole(context, 'titleMediumEmphasized');
        return const SizedBox();
      }),
    ));
    expect(plain?.fontSize, theme?.fontSize);
    expect(bold!.fontWeight!.index, greaterThan(plain!.fontWeight!.index));
  });

  test('springs start at 0, overshoot, and end at 1', () {
    const c = ElpianMotion.fastSpatial;
    expect(c.transform(0), 0);
    expect(c.transform(1), 1);
    final peak = [for (var i = 1; i < 100; i++) c.transform(i / 100)]
        .reduce((a, b) => a > b ? a : b);
    expect(peak, greaterThan(1));
  });
}
