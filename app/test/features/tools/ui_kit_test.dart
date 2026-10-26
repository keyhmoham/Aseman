import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/elpian/elpian.dart';
import 'package:aseman/src/features/tools/ui_kit/kit.dart';

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
      await tester
          .tapAt(Offset(chart.left + chart.width * 0.75, chart.bottom - 40));
      await tester.pumpAndSettle();
      expect(selected.single['row'], {'label': 'B', 'value': 5});
      expect(tester.takeException(), isNull);
    });
  });
}
