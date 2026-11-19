import 'package:aseman/src/features/desk/data/desk_api.dart';
import 'package:aseman/src/features/desk/domain/desk_board.dart';
import 'package:aseman/src/features/desk/domain/desk_models.dart';
import 'package:aseman/src/features/desk/presentation/board/board_geometry.dart';
import 'package:aseman/src/features/desk/presentation/board/board_item_view.dart';
import 'package:aseman/src/features/desk/presentation/desk_controller.dart';
import 'package:aseman/src/features/desk/presentation/free_desk.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A node keeping one desk's windows and whiteboard items, applying ops the
/// way spaces/desk_board.go does (without its validation).
class _Node {
  _Node({List<Map<String, dynamic>> windows = const []})
    : windows = [for (final w in windows) Map<String, dynamic>.of(w)];

  final List<Map<String, dynamic>> windows;
  final List<Map<String, dynamic>> items = [];
  final ops = <Map<String, dynamic>>[];
  Map<String, dynamic>? lastViewport;
  int version = 1;
  int z = 0;

  Map<String, dynamic> get desk => {
    'version': version,
    'viewport': {'w': 900, 'h': 700},
    'windows': windows,
    'pins': const <Object>[],
    'items': items,
  };

  Map<String, dynamic>? _item(Object? id) =>
      items.where((i) => i['id'] == id).firstOrNull;

  DeskApi get api => DeskApi((ns, action, body, {timeout}) async {
    if (action == 'desktop_get') return {'desktop': desk};
    final ids = <String>[];
    for (final op in (body['ops'] as List).cast<Map<String, dynamic>>()) {
      ops.add(op);
      switch (op['op']) {
        case 'item_add':
          items.add({...(op['item'] as Map<String, dynamic>), 'id': op['id'], 'z': ++z});
          ids.add(op['id'] as String);
        case 'item_update':
          final it = _item(op['id']);
          if (it != null) {
            (op['item'] as Map<String, dynamic>).forEach((k, v) {
              v == null ? it.remove(k) : it[k] = v;
            });
          }
          ids.add(op['id'] as String);
        case 'item_remove':
          items.removeWhere((i) => i['id'] == op['id']);
          // The node frees arrow ends that were stuck to it.
          ids.add(op['id'] as String);
        case 'item_front':
          _item(op['id'])?['z'] = ++z;
          ids.add(op['id'] as String);
        case 'move':
          final w = windows.firstWhere((w) => w['id'] == op['id']);
          w
            ..['x'] = op['x']
            ..['y'] = op['y']
            ..['w'] = op['w']
            ..['h'] = op['h'];
          ids.add(op['id'] as String);
        case 'focus':
          windows.firstWhere((w) => w['id'] == op['id'])['z'] = ++z;
          ids.add(op['id'] as String);
        case 'viewport':
          lastViewport = op;
          ids.add('');
        default:
          ids.add('');
      }
    }
    if (ops.last['op'] != 'viewport') version++;
    return {'desktop': desk, 'ids': ids};
  });
}

Map<String, dynamic> _note(String id, double x, double y, {String text = ''}) => {
  'id': id,
  'kind': 'note',
  'x': x,
  'y': y,
  'w': 200,
  'h': 140,
  'z': 1,
  'text': text,
};

Map<String, dynamic> _window(String id, double x, double y) => {
  'id': id,
  'tool': 'wx',
  'name': 'Weather',
  'title': 'Weather $id',
  'x': x,
  'y': y,
  'w': 320,
  'h': 260,
  'z': 1,
};

void main() {
  group('whiteboard items', () {
    test('survive the wire and can be put back as they were', () {
      final item = DeskItem.fromJson({
        'id': 'a1',
        'kind': 'arrow',
        'from': {'ref': 'n1'},
        'to': {'x': 120.4, 'y': 80},
        'text': 'then',
        'head': 'arrow',
        'dash': 'dashed',
        'color': 'teal',
        'width': 3,
      });
      expect(item.isArrow, isTrue);
      expect(item.from!.stuck, isTrue);
      expect(item.to!.point, const Offset(120.4, 80));
      final json = item.toJson();
      expect(json['from'], {'ref': 'n1'});
      expect(json['to'], {'x': 120.0, 'y': 80.0});
      // A patch clears the fields the item lacks.
      final patch = item.toPatch();
      expect(patch.containsKey('fill'), isTrue);
      expect(patch['fill'], isNull);
      expect(patch.containsKey('id'), isFalse);

      final stroke = DeskItem.fromJson({
        'id': 's',
        'kind': 'stroke',
        'x': 10,
        'y': 20,
        'w': 40,
        'h': 60,
        'points': [
          {'x': 10, 'y': 20},
          {'x': 50, 'y': 80},
        ],
      });
      final moved = stroke.shifted(const Offset(5, 5));
      expect(moved.points.last, const Offset(55, 85));
      expect(moved.rect.topLeft, const Offset(15, 25));
    });

    test('a desk without items still parses', () {
      expect(DeskState.fromJson({'version': 3}).items, isEmpty);
      final s = DeskState.fromJson({
        'items': [_note('n', 1, 2, text: 'hi')],
      });
      expect(s.items.single.text, 'hi');
    });
  });

  group('board geometry', () {
    test('an arrow leaves each box on the side that faces the other', () {
      const a = BoardTarget(Rect.fromLTWH(0, 0, 100, 100));
      const b = BoardTarget(Rect.fromLTWH(300, 0, 100, 100));
      final arrow = DeskItem(
        id: 'x',
        kind: 'arrow',
        from: const DeskEnd(ref: 'a'),
        to: const DeskEnd(ref: 'b'),
        path: 'straight',
      );
      final shape = arrowShape(arrow, (r) => r == 'a' ? a : b)!;
      expect(shape.start.dx, closeTo(104, .01));
      expect(shape.end.dx, closeTo(296, .01));
      expect(shape.start.dy, closeTo(50, .01));
      expect(shape.distanceTo(const Offset(200, 53)), lessThan(4));
      expect(shape.distanceTo(const Offset(200, 120)), greaterThan(60));
    });

    test('shapes are met at their outline, not their bounding box', () {
      const ellipse = BoardTarget(Rect.fromLTWH(0, 0, 200, 100), shape: 'ellipse');
      const diamond = BoardTarget(Rect.fromLTWH(0, 0, 200, 100), shape: 'diamond');
      // Toward a corner of the box: the ellipse and the diamond are well inside it.
      final e = boundaryPoint(ellipse, const Offset(400, 200), gap: 0);
      final d = boundaryPoint(diamond, const Offset(400, 200), gap: 0);
      expect(e.dx, lessThan(190));
      expect(d.dx, lessThan(e.dx));
      expect(((e.dx - 100) / 100) * ((e.dx - 100) / 100) + ((e.dy - 50) / 50) * ((e.dy - 50) / 50), closeTo(1, .001));
    });

    test('an arrow whose end is gone is not drawn; free ends need nothing', () {
      final stuck = DeskItem(id: 'x', kind: 'arrow', from: const DeskEnd(ref: 'gone'), to: const DeskEnd(point: Offset(5, 5)));
      expect(arrowShape(stuck, (_) => null), isNull);
      final free = DeskItem(id: 'y', kind: 'arrow', from: const DeskEnd(point: Offset.zero), to: const DeskEnd(point: Offset(50, 50)), path: 'elbow');
      expect(arrowShape(free, (_) => null), isNotNull);
    });
  });

  group('desk controller whiteboard', () {
    test('adds, edits, removes and undoes them, and the node follows', () async {
      final node = _Node();
      final c = DeskController(node.api, pollEvery: const Duration(hours: 1));
      c.attach('s', 'r');
      await c.refresh(force: true);

      final a = c.addItem(const DeskItem(id: '', kind: 'note', rect: Rect.fromLTWH(10, 10, 200, 140), color: 'pink'));
      final b = c.addItem(const DeskItem(id: '', kind: 'shape', rect: Rect.fromLTWH(400, 10, 160, 100), shape: 'ellipse'));
      expect(c.state.items.map((i) => i.id), [a, b], reason: 'at once, before the node answers');
      await Future<void>.delayed(Duration.zero);
      expect(node.items, hasLength(2));
      expect(node.ops.first['op'], 'item_add');
      expect(node.ops.first['id'], a);

      final arrow = c.addItem(DeskItem(id: '', kind: 'arrow', from: DeskEnd(ref: a), to: DeskEnd(ref: b), head: 'arrow'));
      await Future<void>.delayed(Duration.zero);

      await c.updateItem(c.itemById(a)!.copyWith(text: 'plan', rect: const Rect.fromLTWH(30, 10, 200, 140)));
      expect(node.ops.last['op'], 'item_update');
      expect((node.ops.last['item'] as Map)['text'], 'plan');
      expect(c.itemById(a)!.rect.left, 30);

      // An update that changes nothing sends nothing.
      final sent = node.ops.length;
      await c.updateItem(c.itemById(a)!);
      expect(node.ops.length, sent);

      // Removing a note lets go of the arrow that was stuck to it.
      await c.removeItems([a]);
      expect(c.itemById(a), isNull);
      final freed = c.itemById(arrow)!;
      expect(freed.from!.stuck, isFalse);
      expect(freed.from!.point, const Offset(130, 80));
      expect(freed.to!.ref, b);

      // Undo puts the note back and sticks the arrow to it again.
      await c.undo();
      expect(c.itemById(a)!.text, 'plan');
      expect(c.itemById(arrow)!.from!.ref, a);
      // And back the other way.
      await c.redo();
      expect(c.itemById(a), isNull);
      await c.undo();
      await c.undo(); // the text edit
      expect(c.itemById(a)!.text, '');
      expect(c.itemById(a)!.rect.left, 10);
      expect(c.canUndo, isTrue);
      await c.undo(); // the arrow
      expect(c.itemById(arrow), isNull);
      await c.undo();
      await c.undo();
      expect(c.state.items, isEmpty);
      expect(c.canUndo, isFalse);
      expect(c.canRedo, isTrue);
      c.dispose();
    });

    test('a new edit ends the redo history', () async {
      final node = _Node();
      final c = DeskController(node.api, pollEvery: const Duration(hours: 1));
      c.attach('s', 'r');
      await c.refresh(force: true);
      c.addItem(const DeskItem(id: '', kind: 'note', rect: Rect.fromLTWH(0, 0, 200, 140)));
      await c.undo();
      expect(c.canRedo, isTrue);
      c.addItem(const DeskItem(id: '', kind: 'note', rect: Rect.fromLTWH(0, 0, 200, 140)));
      expect(c.canRedo, isFalse);
      c.dispose();
    });

    test('reports whether the screen shows the free desk', () async {
      final node = _Node();
      final c = DeskController(node.api, pollEvery: const Duration(hours: 1));
      c.attach('s', 'r');
      c.reportViewport(const Size(900, 700), free: true);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(node.lastViewport!['args'], {'free': true});
      c.reportViewport(const Size(900, 700));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(node.lastViewport!.containsKey('args'), isFalse);
      c.dispose();
    });
  });

  group('free desk', () {
    Future<(DeskController, _Node)> pump(
      WidgetTester tester, {
      List<Map<String, dynamic>> items = const [],
      List<Map<String, dynamic>> windows = const [],
    }) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final node = _Node(windows: windows)..items.addAll(items);
      final c = DeskController(node.api, pollEvery: const Duration(hours: 1));
      addTearDown(c.dispose);
      c.attach('s', 'r');
      await tester.runAsync(() => c.refresh(force: true));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FreeDesk(
              controller: c,
              windowContent: (context, w) => Center(child: Text('content of ${w.id}')),
              pinPreview: (_) => const SizedBox.shrink(),
              emptyState: const Center(child: Text('empty board')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      return (c, node);
    }

    Finder tool(String name) => find.byKey(ValueKey('board-tool-$name'));

    testWidgets('shows notes, shapes and windows, and says when it is empty', (tester) async {
      final (_, node) = await pump(tester);
      expect(find.text('empty board'), findsOneWidget);
      expect(node.lastViewport?['args'], {'free': true}, reason: 'agents are told the person sees the whiteboard');
    });

    testWidgets('things on the board are drawn', (tester) async {
      await pump(
        tester,
        items: [
          _note('n1', 40, 60, text: 'Remember the milk'),
          {'id': 's1', 'kind': 'shape', 'shape': 'diamond', 'x': 400, 'y': 60, 'w': 160, 'h': 100, 'z': 2, 'text': 'Decide'},
        ],
        windows: [_window('w1', 40, 300)],
      );
      expect(find.text('Remember the milk'), findsOneWidget);
      expect(find.text('Decide'), findsOneWidget);
      expect(find.text('content of w1'), findsOneWidget);
      expect(find.text('empty board'), findsNothing);
    });

    testWidgets('the note tool puts a note where the canvas is tapped, ready to type in', (tester) async {
      final (c, node) = await pump(tester);
      await tester.tap(tool('note'));
      await tester.pump();
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(c.state.items, hasLength(1));
      final note = c.state.items.single;
      expect(note.kind, 'note');
      expect(note.rect.center, const Offset(400, 300));
      expect(find.byType(TextField), findsOneWidget, reason: 'edited in place');
      await tester.enterText(find.byType(TextField), 'Buy flowers');
      // Tapping away ends the edit and keeps the words.
      await tester.tapAt(const Offset(800, 600));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(c.state.items.single.text, 'Buy flowers');
      await tester.pump(const Duration(seconds: 1));
      expect(node.items.single['text'], 'Buy flowers');
      // The tool went back to selecting.
      expect(find.text('Buy flowers'), findsOneWidget);
    });

    testWidgets('dragging a note moves it, at any zoom', (tester) async {
      final (c, _) = await pump(tester, items: [_note('n1', 100, 100, text: 'move me')]);
      await tester.drag(find.text('move me'), const Offset(60, 40));
      await tester.pumpAndSettle();
      expect(c.itemById('n1')!.rect.topLeft, const Offset(160, 140));

      await tester.tap(find.byKey(const ValueKey('board-zoom-in'))); // 125%
      await tester.pumpAndSettle();
      await tester.drag(find.text('move me'), const Offset(125, 0));
      await tester.pumpAndSettle();
      expect(c.itemById('n1')!.rect.left, closeTo(260, 1), reason: '125 screen px at 125% is 100 desk px');
    });

    testWidgets('the arrow tool joins two notes, and the arrow follows them', (tester) async {
      final (c, node) = await pump(
        tester,
        items: [_note('a', 60, 100, text: 'one'), _note('b', 500, 100, text: 'two')],
      );
      await tester.tap(tool('arrow'));
      await tester.pump();
      await tester.dragFrom(const Offset(160, 170), const Offset(500, 0));
      await tester.pumpAndSettle();
      final arrow = c.state.items.firstWhere((i) => i.isArrow);
      expect(arrow.from!.ref, 'a');
      expect(arrow.to!.ref, 'b');
      expect(arrow.head, 'arrow');
      await tester.pump(const Duration(seconds: 1));
      expect(node.items.where((i) => i['kind'] == 'arrow'), hasLength(1));

      // Move a note: the arrow's end still names it.
      await tester.drag(find.text('two'), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(c.itemById('b')!.rect.top, 220);
      expect(c.itemById(arrow.id)!.to!.ref, 'b');
    });

    testWidgets('an arrow can join a note to a window', (tester) async {
      final (c, _) = await pump(
        tester,
        items: [_note('a', 40, 60, text: 'idea')],
        windows: [_window('w1', 500, 60)],
      );
      await tester.tap(tool('arrow'));
      await tester.pump();
      await tester.dragFrom(const Offset(140, 130), const Offset(500, 80));
      await tester.pumpAndSettle();
      final arrow = c.state.items.firstWhere((i) => i.isArrow);
      expect((arrow.from!.ref, arrow.to!.ref), ('a', 'w1'));
    });

    testWidgets('the shape tool drags out a shape; the pen draws a stroke', (tester) async {
      final (c, _) = await pump(tester);
      await tester.tap(tool('shape'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rect'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(100, 100), const Offset(200, 120));
      await tester.pumpAndSettle();
      final shape = c.state.items.single;
      expect(shape.kind, 'shape');
      expect(shape.rect, const Rect.fromLTRB(100, 100, 300, 220));

      await tester.tap(tool('pen'));
      await tester.pump();
      final g = await tester.startGesture(const Offset(500, 400));
      for (var i = 1; i <= 8; i++) {
        await g.moveBy(const Offset(20, 10));
      }
      await g.up();
      await tester.pumpAndSettle();
      final stroke = c.state.items.firstWhere((i) => i.isStroke);
      expect(stroke.points.length, greaterThan(2));
      expect(stroke.points.first, const Offset(500, 400));
    });

    testWidgets('the selection bar recolors, duplicates and deletes; undo brings it back', (tester) async {
      final (c, _) = await pump(tester, items: [_note('n1', 100, 100, text: 'pick me')]);
      await tester.tap(find.text('pick me'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('board-delete')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('board-duplicate')));
      await tester.pumpAndSettle();
      expect(c.state.items, hasLength(2));
      final copy = c.state.items.firstWhere((i) => i.id != 'n1');
      expect(copy.rect.topLeft, const Offset(124, 124));
      expect(copy.text, 'pick me');

      await tester.tap(find.byKey(const ValueKey('board-delete')));
      await tester.pumpAndSettle();
      expect(c.state.items.map((i) => i.id), ['n1']);

      await tester.tap(find.byKey(const ValueKey('board-undo')));
      await tester.pumpAndSettle();
      expect(c.state.items, hasLength(2));
    });

    testWidgets('keys: Delete removes the selection, Ctrl+Z undoes it, V/N pick tools', (tester) async {
      final (c, _) = await pump(tester, items: [_note('n1', 100, 100, text: 'key me')]);
      await tester.tap(find.text('key me'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(c.state.items, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(c.state.items, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tapAt(const Offset(600, 500));
      await tester.pumpAndSettle();
      expect(c.state.items, hasLength(2), reason: 'N chose the note tool');
    });

    testWidgets('resize handles resize a note', (tester) async {
      final (c, _) = await pump(tester, items: [_note('n1', 100, 100, text: 'size me')]);
      await tester.tap(find.text('size me'));
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const ValueKey('resize-1-1')), const Offset(50, 30));
      await tester.pumpAndSettle();
      expect(c.itemById('n1')!.rect, const Rect.fromLTWH(100, 100, 250, 170));
    });

    testWidgets('windows are draggable cards on the board', (tester) async {
      final (c, node) = await pump(tester, windows: [_window('w1', 100, 100)]);
      expect(find.text('content of w1'), findsOneWidget);
      final title = find.text('Weather w1');
      await tester.drag(title, const Offset(-150, -40));
      await tester.pumpAndSettle();
      expect(node.ops.where((o) => o['op'] == 'move'), isNotEmpty);
      final w = c.state.windows.single;
      expect(w.rect.topLeft, const Offset(-50, 60), reason: 'past the desk\'s old edge, as a free board allows');
    });

    testWidgets('the zoom pill zooms and fits', (tester) async {
      await pump(tester, items: [_note('near', 0, 0, text: 'near'), _note('far', 3000, 2000, text: 'far away')]);
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('board-fit')));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsNothing);
      expect(find.text('far away'), findsOneWidget, reason: 'fitted into view');
      await tester.tap(find.byKey(const ValueKey('board-zoom-out')));
      await tester.pumpAndSettle();
      expect(find.byType(BoardItemView), findsNWidgets(2));
    });

    testWidgets('mouse wheel pans, Ctrl+wheel zooms', (tester) async {
      await pump(tester, items: [_note('n1', 100, 100, text: 'pan me')]);
      final before = tester.getTopLeft(find.text('pan me'));
      final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(const Offset(500, 400));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump();
      expect(tester.getTopLeft(find.text('pan me')).dy, closeTo(before.dy - 100, 1));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('100%'), findsNothing);
    });

    testWidgets('something an agent adds out of sight is pointed out', (tester) async {
      final (c, node) = await pump(tester, items: [_note('n1', 100, 100, text: 'here')]);
      node.items.add(_note('far', 5000, 4000, text: 'agent note'));
      node.version++;
      await tester.runAsync(() => c.refresh(force: true));
      await tester.pump();
      expect(find.byKey(const ValueKey('board-new-offscreen')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('board-new-offscreen')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('board-new-offscreen')), findsNothing);
      expect(find.text('agent note'), findsOneWidget);
    });
  });
}
