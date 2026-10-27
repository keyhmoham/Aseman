// Generated programs put values of the wrong type anywhere: "ellipsis" where
// an enum belongs, "true" for a bool, a number for a string, a list for a
// word. Every prop and style key the validator knows is fed such values, and
// none may throw: an odd value reads as absent or as the nearest sensible one.
import 'dart:convert';
import 'dart:io';

import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/features/tools/ui_kit/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final spec = jsonDecode(File('test/elpian/fixtures/prop_names.json').readAsStringSync()) as Map<String, dynamic>;
  final types = (spec['types'] as Map).cast<String, dynamic>();
  final style = (spec['style'] as List).cast<String>();
  const values = <Object>['ellipsis', '', -5, 1e9, true, [1], {'a': 1}];

  // Flex children are checked inside a Row, where they belong (outside one is
  // a misuse the validator reports, not an odd value).
  Map<String, dynamic> inParent(String type, Map<String, dynamic> node) =>
      const {'Expanded', 'Flexible', 'Spacer'}.contains(type) ? {'type': 'Row', 'children': [node]} : node;

  Future<List<String>> sweep(WidgetTester tester, Iterable<(String, Map<String, dynamic>)> cases) async {
    final engine = kitEngine();
    final failures = <String>[];
    final errors = <String>[];
    final onError = FlutterError.onError;
    final print = debugPrint;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null && m.contains('failed to build')) errors.add(m);
    };
    try {
      for (final (label, tree) in cases) {
        errors.clear();
        await tester.pumpWidget(MaterialApp(theme: AppTheme.dark, home: Scaffold(body: engine.renderFromJson(tree))));
        await tester.pump();
        // Tear down too: a widget that asserted mid-build breaks the unmount.
        await tester.pumpWidget(const SizedBox());
        final thrown = tester.takeException();
        if (thrown != null) errors.add('$thrown');
        // Overflow stripes and a flex style off a Flex are layout notes the
        // validator reports, not crashes.
        errors.removeWhere((e) => e.contains('RenderFlex overflowed') || e.contains('Incorrect use of ParentDataWidget'));
        if (errors.isNotEmpty) failures.add('$label: ${errors.first.split('\n').first}');
      }
    } finally {
      FlutterError.onError = onError;
      debugPrint = print;
    }
    return failures;
  }

  testWidgets('odd prop values never throw', (tester) async {
    final failures = await sweep(tester, [
      for (final t in types.keys)
        for (final p in (types[t] as List).cast<String>())
          for (final v in values)
            ('$t.$p = ${jsonEncode(v)}', inParent(t, {
              'type': t,
              'props': {p: v, if (p != 'text') 'text': 'x'},
              'children': [
                {'type': 'Text', 'props': {'text': 'c'}},
              ],
            })),
    ]);
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('odd style values never throw', (tester) async {
    final failures = await sweep(tester, [
      for (final s in style)
        for (final v in [...values, 'bold'])
          for (final t in ['Text', 'Container', 'Button'])
            ('$t style.$s = ${jsonEncode(v)}', {
              'type': t,
              'props': {'text': 'x', 'style': {s: v}},
              'children': [
                {'type': 'Text', 'props': {'text': 'c'}},
              ],
            }),
    ]);
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('the reported case: Text overflow "ellipsis" draws, ellipsized', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: kitEngine().renderFromJson({
          'type': 'Text',
          'props': {'text': 'A long title', 'overflow': 'ellipsis', 'maxLines': '1', 'softWrap': 'false'},
        }),
      ),
    ));
    expect(tester.takeException(), isNull);
    final text = tester.widget<Text>(find.text('A long title'));
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.maxLines, 1);
    expect(text.softWrap, isFalse);
  });
}
