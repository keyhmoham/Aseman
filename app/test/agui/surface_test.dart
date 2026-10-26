import 'package:aseman/src/agui/agui.dart';
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

  testWidgets('AgUiSurfaceView renders Stat via ui_kit', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AgUiSurfaceView(
          surface: AgUiSurface(
            root: {
              'c': 'Column',
              'children': [
                {
                  'c': 'Stat',
                  'p': {'label': 'Uptime', 'value': '99.9%'}
                },
                {
                  'c': 'Choices',
                  'p': {
                    'question': 'OK?',
                    'options': ['Yes', 'No']
                  }
                },
              ],
            },
          ),
          onReply: (v, {meta}) {},
        ),
      ),
    ));
    expect(find.text('Uptime'), findsOneWidget);
    expect(find.text('99.9%'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
  });
}
