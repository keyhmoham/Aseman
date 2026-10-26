// The desk on phones: windows as compact widgets on a board (packed, shaped,
// sized, dragged), opened in full in a bottom sheet; the node keeps the
// arrangement.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/desk/data/desk_api.dart';
import 'package:aseman/src/features/desk/domain/desk_models.dart';
import 'package:aseman/src/features/desk/presentation/compact_desk.dart';
import 'package:aseman/src/features/desk/presentation/desk_controller.dart';
import 'package:aseman/src/features/desk/presentation/frontend_presentation.dart';

Map<String, dynamic> window(String id, String tool, int order,
        {String shape = '', String size = ''}) =>
    {
      'id': id,
      'tool': tool,
      'name': tool,
      'title': 'Window $id',
      'x': 16,
      'y': 16,
      'w': 460,
      'h': 560,
      'z': order,
      'compact': {
        'order': order,
        if (shape.isNotEmpty) 'shape': shape,
        if (size.isNotEmpty) 'size': size,
      },
    };

/// A controller over a fake node that records the ops it gets.
(DeskController, List<Map<String, dynamic>>) fakeDesk(
    List<Map<String, dynamic>> windows) {
  final ops = <Map<String, dynamic>>[];
  var version = 1;
  final list = [for (final w in windows) Map<String, dynamic>.of(w)];
  Map<String, dynamic> desktop() =>
      {'version': version, 'windows': list, 'pins': <Object>[]};
  // What the node does with an arrange (services/plugins/actions/spaces).
  void arrange(Map<String, dynamic> op) {
    list.sort((a, b) =>
        (a['compact']['order'] as int).compareTo(b['compact']['order'] as int));
    final w = list.firstWhere((x) => x['id'] == op['id']);
    final c = op['compact'] as Map;
    list
      ..remove(w)
      ..insert((c['order'] as int).clamp(0, list.length), w);
    w['compact'] = {
      ...(w['compact'] as Map),
      if (c['shape'] != null) 'shape': c['shape'],
      if (c['size'] != null) 'size': c['size'],
    };
    for (var i = 0; i < list.length; i++) {
      list[i]['compact'] = {...(list[i]['compact'] as Map), 'order': i};
    }
  }

  final controller =
      DeskController(DeskApi((ns, action, body, {timeout}) async {
    if (action == 'desktop_update') {
      for (final op in (body['ops'] as List).cast<Map<String, dynamic>>()) {
        ops.add(op);
        if (op['op'] == 'arrange') arrange(op);
        if (op['op'] == 'close') list.removeWhere((w) => w['id'] == op['id']);
      }
      version++;
      return {'desktop': desktop(), 'ids': <String>[]};
    }
    return {'desktop': desktop()};
  }), pollEvery: const Duration(hours: 1));
  controller.attach('s1', 'r1');
  return (controller, ops);
}

Widget phone(DeskController c) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Scaffold(
          body: CompactDesk(
            controller: c,
            windowContent: (context, w) => Text(
                '${w.title}: ${FrontendPresentation.displayOf(context).name}'),
            pinPreview: (p) => const SizedBox(),
          ),
        ),
      ),
    );

void main() {
  test('widgets pack densely in order, each by its size and shape', () {
    final spans = [
      boardSpan('medium', 'card', 2), // a full row
      boardSpan('small', 'card', 2),
      boardSpan('large', 'card', 2),
      boardSpan('small', 'circle', 2), // fills the hole next to the small
      boardSpan('medium', 'circle', 2), // a circle is one cell
    ];
    final slots = packBoard(spans, 2);
    String at(int i) => '${slots[i].column},${slots[i].row}';
    expect(at(0), '0,0');
    expect(at(1), '0,1');
    expect(at(2), '0,2');
    expect(slots[2].span.rows, 2);
    expect(at(3), '1,1');
    expect(at(4), '0,4');
    expect(slots[4].span.columns, 1);
  });

  test('the board order and the arrangement survive JSON', () {
    final state = DeskState.fromJson({
      'windows': [
        window('a', 't1', 2, shape: 'leaf', size: 'large'),
        window('b', 't2', 0),
        {...window('c', 't3', 0)}..remove('compact'),
        window('d', 't4', 1),
      ]
    });
    expect([for (final w in state.boardOrder) w.id], ['b', 'd', 'a', 'c']);
    final a = state.windows.first.compact!;
    expect((a.shape, a.size), ('leaf', 'large'));
    expect(a.toJson(), {'order': 2, 'shape': 'leaf', 'size': 'large'});
    expect(
        DeskOps.arrange('a', order: 1, shape: 'pill'),
        {
          'op': 'arrange',
          'id': 'a',
          'compact': {'order': 1, 'shape': 'pill'}
        });
  });

  testWidgets('every window is a compact widget that opens in a sheet',
      (tester) async {
    final (c, _) = fakeDesk([window('a', 't1', 0), window('b', 't2', 1)]);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(phone(c));
    await tester.pumpAndSettle();
    expect(find.text('Window a: compact'), findsOneWidget);
    expect(find.text('Window b: compact'), findsOneWidget);
    expect(find.byType(CompactWidgetTile), findsNWidgets(2));

    await tester.tap(find.text('Window a: compact'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Window a: sheet'), findsOneWidget,
        reason: 'the full frontend, in the sheet');
    await tester.tap(find.byTooltip('Minimize'));
    await tester.pumpAndSettle();
    expect(find.text('Window a: sheet'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('the menu sets a widget\'s size and shape on the node',
      (tester) async {
    final (c, ops) = fakeDesk([window('a', 't1', 0), window('b', 't2', 1)]);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(phone(c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('App options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Circle'));
    await tester.pumpAndSettle();
    expect(ops.last['op'], 'arrange');
    expect(ops.last['compact'], {'order': 0, 'shape': 'circle', 'size': 'small'});
    Navigator.of(tester.element(find.text('Circle'))).pop();
    await tester.pumpAndSettle();
    final tile = tester.widget<CompactWidgetTile>(
        find.byType(CompactWidgetTile).first);
    expect((tile.shape, tile.size), ('circle', 'small'));
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('dragging a widget onto another moves it there',
      (tester) async {
    final (c, ops) = fakeDesk(
        [window('a', 't1', 0), window('b', 't2', 1), window('c', 't3', 2)]);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(phone(c));
    await tester.pumpAndSettle();
    final from = tester.getCenter(find.text('Window c: compact'));
    final to = tester.getCenter(find.text('Window a: compact'));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 700)); // long-press
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ops.last, {
      'op': 'arrange',
      'id': 'c',
      'compact': {'order': 0}
    });
    expect([for (final w in c.state.boardOrder) w.id], ['c', 'a', 'b']);
    expect(
        tester.getTopLeft(find.text('Window c: compact')).dy <
            tester.getTopLeft(find.text('Window a: compact')).dy,
        isTrue);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a frontend\'s look hint shapes its widget until one is chosen',
      (tester) async {
    final (c, _) = fakeDesk([window('a', 't1', 0)]);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompactDesk(
          controller: c,
          windowContent: (context, w) {
            final p = FrontendPresentation.maybeOf(context);
            if (p?.display == FrontendDisplay.compact) {
              WidgetsBinding.instance.addPostFrameCallback((_) => p!.onHint
                  ?.call(const CompactHint(shape: 'pill', size: 'medium')));
            }
            return const Text('content');
          },
          pinPreview: (p) => const SizedBox(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final tile =
        tester.widget<CompactWidgetTile>(find.byType(CompactWidgetTile));
    expect(tile.shape, 'pill');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
