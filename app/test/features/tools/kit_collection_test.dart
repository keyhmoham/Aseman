// The UI kit's wider collection: every chart, table and app widget renders
// with realistic data (light and dark, phone and desk widths) and sends its
// events.
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/elpian/elpian.dart';
import 'package:aseman/src/features/tools/ui_kit/kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'];

/// Sample props for each new node type.
final Map<String, Map<String, dynamic>> samples = {
  'Funnel': {
    'title': 'Signup funnel',
    'data': [
      {'label': 'Visited', 'value': 12400},
      {'label': 'Signed up', 'value': 3100},
      {'label': 'Activated', 'value': 1800},
      {'label': 'Paid', 'value': 420},
    ],
  },
  'Waterfall': {
    'title': 'Cash flow',
    'start': 1200,
    'format': 'currency:USD:0',
    'data': [
      {'label': 'Sales', 'value': 800},
      {'label': 'Refunds', 'value': -150},
      {'label': 'Payroll', 'value': -600},
      {'label': 'Q1', 'total': true},
      {'label': 'Grants', 'value': 300},
    ],
  },
  'Sankey': {
    'title': 'Traffic',
    'links': [
      {'from': 'Search', 'to': 'Landing', 'value': 50},
      {'from': 'Social', 'to': 'Landing', 'value': 20},
      {'from': 'Landing', 'to': 'Signup', 'value': 30},
      {'from': 'Landing', 'to': 'Bounce', 'value': 40},
      {'from': 'Signup', 'to': 'Paid', 'value': 10},
    ],
  },
  'Gantt': {
    'title': 'Launch plan',
    'data': [
      {'label': 'Design', 'start': '2026-10-01', 'end': '2026-10-14', 'progress': 1, 'group': 'Product'},
      {'label': 'Build', 'start': '2026-10-10', 'end': '2026-11-08', 'progress': 0.4, 'group': 'Eng'},
      {'label': 'Beta', 'start': '2026-11-09', 'end': '2026-11-09'},
    ],
  },
  'BoxPlot': {
    'data': [
      {'label': 'A', 'values': [3, 4, 5, 5, 6, 7, 8, 22]},
      {'label': 'B', 'min': 1, 'q1': 3, 'median': 4, 'q3': 6, 'max': 9},
    ],
  },
  'BulletChart': {
    'items': [
      {'label': 'Revenue', 'value': 270, 'target': 250, 'ranges': [150, 225, 300], 'format': 'currency:USD:0'},
      {'label': 'NPS', 'value': 42, 'target': 50, 'ranges': [20, 40, 60]},
    ],
  },
  'SegmentedBar': {
    'title': 'Storage',
    'data': [
      {'label': 'Photos', 'value': 40},
      {'label': 'Video', 'value': 25},
      {'label': 'Docs', 'value': 10},
    ],
  },
  'RadialBars': {
    'data': [
      {'label': 'Move', 'value': 420, 'max': 500},
      {'label': 'Exercise', 'value': 28, 'max': 30},
      {'label': 'Stand', 'value': 13, 'max': 12},
    ],
    'centerLabel': '84%',
    'centerCaption': 'today',
  },
  'Sunburst': {
    'data': [
      {
        'label': 'Eng',
        'children': [
          {'label': 'Web', 'value': 5},
          {'label': 'Apps', 'value': 3},
        ]
      },
      {'label': 'Sales', 'value': 4},
    ],
  },
  'CalendarHeatmap': {
    'end': '2026-10-26',
    'weeks': 20,
    'data': [
      for (var i = 0; i < 90; i++) {'date': DateTime(2026, 10, 26).subtract(Duration(days: i)).toIso8601String(), 'value': i % 7},
    ],
  },
  'WordCloud': {
    'data': [
      for (final (i, w) in ['flutter', 'elpian', 'aseman', 'charts', 'material', 'expressive', 'agents', 'widgets'].indexed) {'text': w, 'value': 10 - i},
    ],
  },
  'PivotTable': {
    'rows': 'region',
    'columns': 'quarter',
    'value': 'sales',
    'format': 'compact',
    'data': [
      {'region': 'EU', 'quarter': 'Q1', 'sales': 120},
      {'region': 'EU', 'quarter': 'Q2', 'sales': 140},
      {'region': 'US', 'quarter': 'Q1', 'sales': 200},
      {'region': 'US', 'quarter': 'Q2', 'sales': 180},
    ],
  },
  'Leaderboard': {
    'highlight': 'Bo',
    'data': [
      {'name': 'Ann', 'value': 980, 'change': 2},
      {'name': 'Bo', 'value': 870, 'subtitle': 'You'},
      {'name': 'Cy', 'value': 640, 'change': -1},
      {'name': 'Di', 'value': 300},
    ],
  },
  'Tabs': {
    'tabs': [
      {'label': 'Overview', 'icon': 'dashboard'},
      {'label': 'Activity', 'icon': 'timeline', 'badge': 3},
      'Settings',
    ],
  },
  'Calendar': {
    'month': '2026-10',
    'selected': '2026-10-26',
    'events': [
      {'date': '2026-10-26', 'title': 'Standup', 'time': '09:30'},
      {'date': '2026-10-28', 'title': 'Launch', 'status': 'good'},
    ],
  },
  'Kanban': {
    'columns': [
      {
        'title': 'To do',
        'cards': [
          {'title': 'Write docs', 'tags': ['docs'], 'assignee': 'Ann', 'due': 'Fri'},
        ]
      },
      {
        'title': 'Doing',
        'cards': [
          {'title': 'Ship charts', 'priority': 'warning'}
        ]
      },
      {'title': 'Done', 'cards': <Map<String, dynamic>>[]},
    ],
  },
  'Carousel': {
    'height': 160,
    'items': [
      {'title': 'Welcome', 'subtitle': 'Swipe to explore'},
      {'title': 'Charts'},
    ],
  },
  'Stepper': {
    'current': 1,
    'steps': [
      {'title': 'Cart'},
      {'title': 'Shipping', 'subtitle': 'Address and speed'},
      {'title': 'Payment'},
    ],
  },
  'Chat': {
    'typing': true,
    'suggestions': ['Summarize', 'Make it shorter'],
    'messages': [
      {'role': 'system', 'text': 'Today'},
      {'role': 'user', 'text': 'Can you **summarize** the report?', 'time': '9:41'},
      {'role': 'assistant', 'name': 'Research', 'text': 'Sure — revenue is up `12%`. See [the report](https://example.com).'},
      {'role': 'assistant', 'text': 'Anything else?'},
    ],
  },
  'Countdown': {'seconds': 3725, 'label': 'Sale ends in'},
  'Clock': {'label': 'Tehran', 'utcOffset': 3.5},
  'EmptyState': {'icon': 'inbox', 'title': 'No orders yet', 'text': 'New orders show up here.', 'action': 'Create order'},
  'AvatarGroup': {'names': ['Ann Lee', 'Bo Chen', 'Cy Diaz', 'Di Evans', 'Ed Fox', 'Flo Gray']},
  'Pagination': {'page': 5, 'pages': 12},
  'Breadcrumbs': {
    'items': [
      {'label': 'Home', 'icon': 'home'},
      'Projects',
      'Aseman',
    ]
  },
  'Markdown': {
    'text': '# Release notes\n\nThis is **bold**, *italic*, `code` and a [link](https://aseman.app).\n\n'
        '- one\n  - nested\n- [x] done task\n1. first\n\n> A quote\n\n```dart\nvoid main() {}\n```\n\n| Name | Value |\n|---|---|\n| a | 1 |\n\n---\n',
  },
  'LogView': {
    'title': 'build.log',
    'lines': ['10:01:02 INFO starting build', '10:01:05 WARN slow step', {'time': '10:01:09', 'level': 'error', 'message': 'failed', 'source': 'cc'}],
  },
  'DiffView': {'title': 'main.dart', 'before': 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj', 'after': 'a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk'},
  'QRCode': {'data': 'https://aseman.app', 'label': 'Scan to open'},
};

Future<void> pump(WidgetTester tester, Map<String, dynamic> tree, {ThemeData? theme, double width = 420}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final engine = kitEngine();
  await tester.pumpWidget(MaterialApp(
    theme: theme ?? AppTheme.light,
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Builder(builder: (_) => engine.renderFromJson(tree)))),
  ));
  await tester.pump(const Duration(milliseconds: 900));
}

Map<String, dynamic> node(String type, [Map<String, dynamic>? events]) => {
      'type': type,
      'key': type,
      'props': samples[type],
      if (type == 'Tabs' || type == 'Carousel')
        'children': [
          for (final t in ['Panel one', 'Panel two', 'Panel three'])
            {'type': 'Text', 'props': {'text': t}}
        ],
      'events': ?events,
    };

void main() {
  for (final type in samples.keys) {
    for (final (dark, width) in [(false, 420.0), (true, 1100.0)]) {
      testWidgets('$type renders (${dark ? 'dark, desk' : 'light, phone'})', (tester) async {
        await pump(tester, {'type': 'Column', 'children': [node(type)]}, theme: dark ? AppTheme.dark : AppTheme.light, width: width);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('every new node is a kit node and a Chart type routes', (tester) async {
    for (final t in samples.keys) {
      expect(kitTypes, contains(t));
    }
    await pump(tester, {
      'type': 'Column',
      'children': [
        for (final t in ['funnel', 'waterfall', 'sankey', 'gantt', 'boxplot', 'sunburst', 'segmented', 'calendar', 'wordcloud'])
          {
            'type': 'Chart',
            'props': {
              'type': t,
              ...samples[{'funnel': 'Funnel', 'waterfall': 'Waterfall', 'sankey': 'Sankey', 'gantt': 'Gantt', 'boxplot': 'BoxPlot', 'sunburst': 'Sunburst', 'segmented': 'SegmentedBar', 'calendar': 'CalendarHeatmap', 'wordcloud': 'WordCloud'}[t]]!,
            }
          },
      ],
    });
    expect(tester.takeException(), isNull);
    expect(find.byType(SankeyChart), findsOneWidget);
    expect(find.byType(GanttChart), findsOneWidget);
  });

  testWidgets('the widgets send their events', (tester) async {
    final got = <String, List<Map<String, dynamic>>>{};
    void Function(ElpianEvent) rec(String k) => (e) => (got[k] ??= []).add(e.data);
    await pump(tester, {
      'type': 'Column',
      'children': [
        node('Tabs', {'change': rec('tabs')}),
        node('Calendar', {'select': rec('calendar'), 'change': rec('month')}),
        node('Pagination', {'change': rec('page')}),
        node('Breadcrumbs', {'select': rec('crumb')}),
        node('EmptyState', {'action': rec('empty')}),
        node('Chat', {'select': rec('chat')}),
        node('Funnel', {'select': rec('funnel')}),
        node('Stepper', {'select': rec('step')}),
        node('Kanban', {'select': rec('card')}),
        node('Markdown', {'link': rec('link')}),
      ],
    }, width: 900);

    await tester.tap(find.text('Activity'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(got['tabs']?.last['value'], 1);
    expect(find.text('Panel two'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(KitCalendar), matching: find.text('28')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(got['calendar']?.last['date'], '2026-10-28');
    expect((got['calendar']!.last['events'] as List).length, 1);
    await tester.tap(find.byTooltip('Next month'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(got['month']?.last['month'], '2026-11');

    await tester.tap(find.descendant(of: find.byType(KitPagination), matching: find.text('6')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(got['page']?.last['value'], 6);

    await tester.tap(find.text('Projects'));
    expect(got['crumb']?.last, {'index': 1, 'label': 'Projects'});

    await tester.tap(find.text('Create order'));
    expect(got['empty']?.length, 1);

    await tester.tap(find.text('Summarize'));
    expect(got['chat']?.last['text'], 'Summarize');

    await tester.tap(find.descendant(of: find.byType(FunnelChart), matching: find.text('Paid')));
    expect(got['funnel']?.last['label'], 'Paid');

    await tester.tap(find.descendant(of: find.byType(KitStepper), matching: find.text('3')));
    expect(got['step']?.last['index'], 2);

    await tester.tap(find.text('Write docs'));
    expect(got['card']?.last['card']['title'], 'Write docs');

    // A link is a span inside the paragraph: run its recognizer.
    final para = tester.widgetList<RichText>(find.byType(RichText)).firstWhere((r) => r.text.toPlainText().contains('This is bold'));
    TapGestureRecognizer? link;
    para.text.visitChildren((span) {
      if (span is TextSpan && span.text == 'link') link = span.recognizer as TapGestureRecognizer?;
      return link == null;
    });
    link!.onTap!();
    expect(got['link']?.last['href'], 'https://aseman.app');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a kanban card dragged to another column reports the move', (tester) async {
    final moves = <Map<String, dynamic>>[];
    await pump(tester, node('Kanban', {'move': (ElpianEvent e) => moves.add(e.data)}), width: 1100);
    final card = tester.getCenter(find.text('Write docs'));
    final target = tester.getCenter(find.text('Done'));
    final g = await tester.startGesture(card);
    await tester.pump(const Duration(milliseconds: 700));
    await g.moveTo(target + const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 100));
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(moves.single['from'], 0);
    expect(moves.single['to'], 2);
    expect(moves.single['card']['title'], 'Write docs');
  });

  testWidgets('charts report the mark under a tap', (tester) async {
    final picks = <String, Map<String, dynamic>>{};
    await pump(tester, {
      'type': 'Column',
      'children': [
        node('Waterfall', {'select': (ElpianEvent e) => picks['waterfall'] = e.data}),
        node('PivotTable', {'select': (ElpianEvent e) => picks['pivot'] = e.data}),
      ],
    }, width: 600);
    final wf = tester.getRect(find.byType(WaterfallChart));
    // The second bar of six (Sales).
    await tester.tapAt(Offset(wf.left + 44 + (wf.width - 48) / 6 * 1.5, wf.bottom - 80));
    expect(picks['waterfall']?['label'], 'Sales');
    await tester.tap(find.text('200'));
    expect(picks['pivot'], {'row': 'US', 'column': 'Q1', 'value': 200.0});
  });

  testWidgets('the diff folds unchanged lines and counts changes', (tester) async {
    await pump(tester, node('DiffView'));
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
    expect(find.textContaining('unchanged lines'), findsOneWidget);
    await tester.tap(find.textContaining('unchanged lines'));
    await tester.pump();
    expect(find.textContaining('unchanged lines'), findsNothing);
  });

  testWidgets('the pivot totals rows and columns', (tester) async {
    await pump(tester, node('PivotTable'), width: 700);
    expect(find.text('Total'), findsNWidgets(2));
    expect(find.text('640'), findsOneWidget); // the grand total
  });
}
