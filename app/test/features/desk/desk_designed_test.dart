import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/desk/data/desk_api.dart';
import 'package:aseman/src/features/desk/presentation/designed_window.dart';
import 'package:aseman/src/features/desk/presentation/desk_controller.dart';

void main() {
  Widget host(String status, Map<String, dynamic> template,
          {DeskController? controller}) =>
      MaterialApp(
        home: Scaffold(
          body: DesignedWindowContent(
            windowId: 'w1',
            request: 'Which notes mention tax?',
            template: template,
            status: status,
            controller: controller,
            ready: (t) => Text('design: ${t['title']}'),
          ),
        ),
      );

  testWidgets('a window being designed says what for, then shows its design',
      (tester) async {
    await tester.pumpWidget(host('designing', const {}));
    await tester.pump();
    expect(
        find.text('Designing this window for your request…'), findsOneWidget);
    expect(find.text('“Which notes mention tax?”'), findsOneWidget);
    await tester.pumpWidget(host('ready', const {'title': 'Tax notes'}));
    expect(find.text('design: Tax notes'), findsOneWidget);
  });

  testWidgets('a failed design says why and can be tried again',
      (tester) async {
    final ops = <Map<String, dynamic>>[];
    final controller =
        DeskController(DeskApi((ns, action, body, {timeout}) async {
      if (action == 'desktop_update') {
        ops.addAll((body['ops'] as List).cast<Map<String, dynamic>>());
      }
      return {
        'desktop': <String, dynamic>{},
        'ids': <String>['w1']
      };
    }), pollEvery: const Duration(hours: 1));
    controller.attach('s1', 'r1');
    await tester.pumpWidget(host('failed: no model is configured', const {},
        controller: controller));
    await tester.pump();
    expect(find.text('This window could not be designed'), findsOneWidget);
    expect(find.text('no model is configured'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(ops.last, {'op': 'redesign', 'id': 'w1'});
    controller.dispose();
  });

  testWidgets('a design stuck for long can be started over', (tester) async {
    await tester.pumpWidget(host('designing', const {},
        controller: DeskController(
            DeskApi((ns, a, b, {timeout}) async => <String, dynamic>{}),
            pollEvery: const Duration(hours: 1))));
    expect(find.text('Start over'), findsNothing);
    await tester.pump(DesignedWindowContent.stale + const Duration(seconds: 1));
    expect(find.text('Start over'), findsOneWidget);
  });
}
