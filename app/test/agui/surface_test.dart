import 'package:aseman/src/agui/agui.dart';
import 'package:aseman/src/features/tools/ui_kit/data_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseAgUiBody extracts fence and caption', () {
    const body = '''
Here is a snapshot

```agui
{"layout":"chat","root":{"c":"Stat","p":{"label":"Temp","value":"21°"}}}
```
''';
    final parsed = parseAgUiBody(body);
    expect(parsed.caption, 'Here is a snapshot');
    expect(parsed.surface, isNotNull);
    expect(typeOf(parsed.surface!.root!), 'Stat');
    expect(propsOf(parsed.surface!.root!)['value'], '21°');
  });

  test('Question surface factory', () {
    final s = AgUiSurface.question('Pick one', options: ['A', 'B']);
    expect(typeOf(s.root!), 'Question');
    expect(propsOf(s.root!)['options'], ['A', 'B']);
  });

  test('chart props accept a points list', () {
    final props = chartPropsForKit({
      'title': 'Sales',
      'points': [
        {'label': 'Jan', 'value': 3},
        {'label': 'Feb', 'value': '9'},
      ],
    });
    expect(props['type'], 'bar');
    expect(props['data'], isA<List>());
  });

  test('callout props map tone and content', () {
    final props = calloutPropsForKit({
      'tone': 'warning',
      'title': 'Careful',
      'content': 'Look out',
    });
    expect(props['severity'], 'warning');
    expect(props['text'], 'Look out');
  });

  testWidgets('AgUiSurfaceView renders Stat via ui_kit', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgUiSurfaceView(
            surface: AgUiSurface(
              root: {
                'c': 'Column',
                'children': [
                  {
                    'c': 'Stat',
                    'p': {'label': 'Uptime', 'value': '99.9%'},
                  },
                  {
                    'c': 'Choices',
                    'p': {
                      'question': 'OK?',
                      'options': ['Yes', 'No'],
                    },
                  },
                ],
              },
            ),
            onReply: (v, {meta}) {},
          ),
        ),
      ),
    );
    expect(find.text('Uptime'), findsOneWidget);
    expect(find.text('99.9%'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
  });

  testWidgets('a chart sent as points draws, and markdown is not a raw fence', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgUiSurfaceView(
            surface: AgUiSurface(
              title: 'Snapshot',
              root: {
                'c': 'Column',
                'children': [
                  {
                    'c': 'Chart',
                    'p': {
                      'title': 'Sales',
                      'points': [
                        {'label': 'Jan', 'value': 3},
                        {'label': 'Feb', 'value': 9},
                      ],
                    },
                  },
                  {
                    'c': 'Markdown',
                    'p': {'content': '```chart\ntitle: Load\nA: 1\nB: 2\n```'},
                  },
                  {
                    'c': 'Callout',
                    'p': {'tone': 'warning', 'content': 'Heads up'},
                  },
                ],
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Sales'), findsOneWidget);
    expect(find.text('No data'), findsNothing);
    expect(find.text('Load'), findsOneWidget);
    expect(find.text('Heads up'), findsOneWidget);
    expect(find.textContaining('```'), findsNothing);
  });

  testWidgets('a forecast table shows its cells, and a card shows its fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              DataGrid(
                props: {
                  'title': 'Rasht today — full forecast details',
                  'columns': ['Time', 'Temp', 'Conditions'],
                  'rows': [
                    {'time': '13:00', 'temp': '22.4°', 'conditions': 'Clear'},
                    ['16:00', '19.8°', 'Partly cloudy'],
                  ],
                },
              ),
              AgUiSurfaceView(
                surface: AgUiSurface(
                  root: {
                    'c': 'Card',
                    'p': {
                      'title': 'Rasht — current conditions',
                      'children': [
                        {
                          'c': 'KeyValue',
                          'p': {
                            'items': [
                              {'name': 'Condition', 'text': 'Clear'},
                              {'name': 'Humidity', 'text': '59%'},
                            ],
                          },
                        },
                      ],
                    },
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('13:00'), findsOneWidget);
    expect(find.text('22.4°'), findsOneWidget);
    expect(find.text('Clear'), findsWidgets);
    expect(find.text('16:00'), findsOneWidget);
    expect(find.text('Partly cloudy'), findsOneWidget);
    expect(find.text('Humidity'), findsOneWidget);
    expect(find.text('59%'), findsOneWidget);
  });

  testWidgets('a conditions card shows its fields instead of an empty body', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgUiSurfaceView(
            surface: AgUiSurface(
              root: {
                'c': 'Card',
                'p': {
                  'title': 'Rasht — current conditions',
                  'fields': [
                    {'Condition': 'Clear'},
                    {'Humidity': '59%'},
                  ],
                  'children': [
                    {
                      'c': 'Chart',
                      'p': {
                        'type': 'line',
                        'height': 240,
                        'data': [
                          {
                            'condition': 'Clear',
                            'temperature_text': '22.4°C',
                            'humidity_text': '59%',
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Rasht — current conditions'), findsOneWidget);
    expect(find.text('Clear'), findsWidgets);
    expect(find.text('22.4°C'), findsOneWidget);
    expect(find.text('59%'), findsWidgets);
    expect(find.text('No data'), findsNothing);
  });

  testWidgets('a facts card shows each label and value', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgUiSurfaceView(
            surface: AgUiSurface(
              root: {
                'c': 'Column',
                'children': [
                  {
                    'c': 'KeyValue',
                    'p': {'label': 'Temperature', 'value': '13.1°C'},
                  },
                  {
                    'c': 'KeyValue',
                    'p': {'label': 'Humidity', 'value': '93%'},
                  },
                  {
                    'c': 'KeyValue',
                    'p': {'label': 'Conditions', 'value': 'Light rain'},
                  },
                ],
              },
              title: 'Selected: current conditions in Rasht',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Selected: current conditions in Rasht'), findsOneWidget);
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.text('13.1°C'), findsOneWidget);
    expect(find.text('Humidity'), findsOneWidget);
    expect(find.text('93%'), findsOneWidget);
    expect(find.text('Light rain'), findsOneWidget);
  });

  test('a card still being written is pending, never half a JSON tree', () {
    final streaming = parseAgUiBody('Here you go.\n\n```agui\n{"title":"Sal');
    expect(streaming.surface, isNull);
    expect(streaming.pending, isTrue);
    expect(streaming.caption, 'Here you go.');
    // A closed fence with CRLF line ends still parses.
    final crlf = parseAgUiBody('```agui\r\n{"root":{"c":"Text"}}\r\n```');
    expect(crlf.surface?.root, isNotNull);
    expect(crlf.pending, isFalse);
  });

  test('a half-written replies line is not shown', () {
    expect(parseReplies('Shall I?\n<replies>Yes | N').text, 'Shall I?');
    expect(parseReplies('Shall I?\n<repl').text, 'Shall I?');
    expect(parseReplies('2 < 3').text, '2 < 3');
  });

  test('a card that brings its frame is not titled twice', () {
    expect(visibleTitle(AgUiSurface.question('Pick one')), '');
    expect(
      visibleTitle(AgUiSurface(title: 'Sales', root: {'c': 'Column'})),
      'Sales',
    );
    expect(
      visibleTitle(
        AgUiSurface(
          title: 'sales',
          root: {
            'c': 'Card',
            'p': {'title': 'Sales'},
          },
        ),
      ),
      '',
    );
  });

  test('form fields get a key each and reply with what was filled in', () {
    final fields = agUiFormFields([
      {'label': 'Name', 'required': true},
      {'label': 'Name'},
      {
        'name': 'pick',
        'options': ['a', 'b'],
        'value': 'a',
      },
      'Notes',
    ]);
    expect(fields.map((f) => f.key), ['Name', 'Name_1', 'pick', 'Notes']);
    expect(fields[2].type, 'select');
    expect(
      agUiFormReady(fields, {
        'Name': '',
        'Name_1': '',
        'pick': 'a',
        'Notes': '',
      }),
      isFalse,
    );
    expect(agUiFormReady(fields, {'Name': 'Ana', 'pick': 'a'}), isTrue);
    expect(
      agUiFormReply(fields, {'Name': 'Ana', 'pick': 'b', 'Notes': ' hi '}),
      'Name: Ana\npick: b\nNotes: hi',
    );
  });

  testWidgets('a question is answered once and keeps its answer', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgUiSurfaceView(
            messageId: 'm1',
            surface: AgUiSurface.question('Which one?', options: ['A', 'B']),
            onReply: (v, {meta}) => sent.add(v),
          ),
        ),
      ),
    );
    expect(find.text('Which one?'), findsOneWidget);
    // The generic "Question" title is not repeated above the card.
    expect(find.text('Question'), findsNothing);
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(sent, ['A']);
    expect(find.text('You answered: '), findsNothing);
    expect(find.textContaining('You answered'), findsOneWidget);
  });

  testWidgets('choices send once, not on every tap', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgUiSurfaceView(
            messageId: 'm2',
            surface: AgUiSurface(
              root: {
                'c': 'Choices',
                'p': {
                  'label': 'Pick',
                  'options': ['X', 'Y'],
                },
              },
            ),
            onReply: (v, {meta}) => sent.add(v),
          ),
        ),
      ),
    );
    await tester.tap(find.text('X'));
    await tester.pump();
    await tester.tap(find.text('X'));
    await tester.tap(find.text('Y'));
    await tester.pump();
    expect(sent, ['X']);
  });

  testWidgets('an unknown part shows its words, not an error', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgUiSurfaceView(
            surface: AgUiSurface(
              root: {
                'c': 'Column',
                'children': [
                  {
                    'c': 'Hologram',
                    'p': {'label': 'Open the door'},
                  },
                  {'c': 'Hologram'},
                ],
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('Open the door'), findsOneWidget);
    expect(find.textContaining('Unknown'), findsNothing);
  });

  testWidgets('a row of stats shares the width', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: AgUiSurfaceView(
              surface: AgUiSurface(
                root: {
                  'c': 'Row',
                  'children': [
                    {
                      'c': 'Stat',
                      'p': {'label': 'A', 'value': '1'},
                    },
                    {
                      'c': 'Stat',
                      'p': {'label': 'B', 'value': '2'},
                    },
                  ],
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final a = tester.getRect(find.text('A'));
    final b = tester.getRect(find.text('B'));
    // Side by side, not stacked.
    expect(a.top, closeTo(b.top, 2));
    expect(b.left, greaterThan(a.right));
  });
}
