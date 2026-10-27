// Generated programs send odd view trees. One odd entry must never take the
// screen down: holes are skipped, scalars drawn, odd props ignored, and a
// node that fails to build draws a small error in its place.
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/elpian/elpian.dart';
import 'package:aseman/src/elpian/vm/quickjs_vm_native.dart' as native;
import 'package:aseman/src/features/tools/ui_kit/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pump(WidgetTester tester, Map<String, dynamic> tree) async {
  final engine = kitEngine();
  await tester.pumpWidget(MaterialApp(theme: AppTheme.dark, home: Scaffold(body: Builder(builder: (_) => engine.renderFromJson(tree)))));
  await tester.pump();
}

void main() {
  testWidgets('a null child (the calculator crash) is skipped, the rest draws', (tester) async {
    // Before: "TypeError: null: type 'Null' is not a subtype of type
    // 'Map<String, dynamic>'" replaced the whole app.
    await pump(tester, {
      'type': 'Column',
      'children': [
        {'type': 'Text', 'props': {'text': '12 ÷ 0'}},
        null,
        {'type': 'Text', 'props': {'text': 'keys'}},
      ],
    });
    expect(tester.takeException(), isNull);
    expect(find.text('12 ÷ 0'), findsOneWidget);
    expect(find.text('keys'), findsOneWidget);
  });

  testWidgets('false, nested arrays, scalars, odd props, keys and styles do not throw', (tester) async {
    await pump(tester, {
      'type': 'Column',
      'children': [
        false,
        true,
        [
          {'type': 'Text', 'props': {'text': 'nested'}}
        ],
        'plain',
        42,
        {'type': 'Text', 'props': [1, 2], 'events': 'tap', 'key': 7},
        {'type': 'Text', 'props': {'text': 'styled', 'style': 'padding: 4px', 'className': 3}},
        {'props': {'text': 'no type'}},
        {'type': 'Card', 'children': {'type': 'Text', 'props': {'text': 'single child object'}}},
      ],
    });
    expect(tester.takeException(), isNull);
    for (final t in ['nested', 'plain', '42', 'styled', 'single child object']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.textContaining('Unknown widget'), findsOneWidget);
  });

  testWidgets('a node that fails to build shows its error; siblings still draw', (tester) async {
    final engine = kitEngine()..registerWidget('Boom', (node, children) => throw StateError('boom'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: engine.renderFromJson({
          'type': 'Column',
          'children': [
            {'type': 'Boom'},
            {'type': 'Text', 'props': {'text': 'still here'}},
          ],
        }),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(NodeErrorBox), findsOneWidget);
    expect(find.textContaining('Boom:'), findsOneWidget);
    expect(find.text('still here'), findsOneWidget);
  });

  test('children are read leniently', () {
    final kids = ElpianNode.childrenOf([
      null,
      false,
      [
        {'type': 'Text'},
        [
          {'type': 'Icon'}
        ]
      ],
      'x',
      <dynamic, dynamic>{'type': 'Row', 1: 'numeric key'},
    ]);
    expect(kids.map((n) => n.type), ['Text', 'Icon', 'Text', 'Row']);
    expect(kids[2].props['text'], 'x');
  });

  test('handler names that are not identifiers are called by lookup', () {
    expect(native.QuickJsVm.callee('__app0_key_\$f7\$'), '__app0_key_\$f7\$');
    expect(native.QuickJsVm.callee('Aseman.settle'), 'Aseman.settle');
    expect(native.QuickJsVm.callee('on press'), 'globalThis["on press"]');
  });
}
