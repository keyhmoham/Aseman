import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/core/theme/default_theme_packs.dart';
import 'package:aseman/src/features/desk/data/desk_api.dart';
import 'package:aseman/src/features/desk/presentation/desk_controller.dart';
import 'package:aseman/src/features/desk/presentation/card_window.dart';
import 'package:aseman/src/features/desk/presentation/floating_desk.dart';

Finder windowChrome(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is WindowChromeButton && widget.tooltip == tooltip,
);

/// A node keeping one desk, applying ops roughly as spaces/desktop.go does.
class _Node {
  _Node(
    List<Map<String, dynamic>> windows, {
    List<Map<String, dynamic>> pins = const [],
  }) : windows = [for (final w in windows) Map<String, dynamic>.of(w)],
       pins = [for (final p in pins) Map<String, dynamic>.of(p)];

  final List<Map<String, dynamic>> windows;
  final List<Map<String, dynamic>> pins;
  final ops = <Map<String, dynamic>>[];
  int version = 1;
  int seq = 0;

  Map<String, dynamic> get desk => {
    'version': version,
    'viewport': {'w': 1200, 'h': 800},
    'windows': windows,
    'pins': pins,
  };

  DeskApi get api => DeskApi((ns, action, body, {timeout}) async {
    if (action == 'desktop_get') return {'desktop': desk};
    final ids = <String>[];
    for (final op in (body['ops'] as List).cast<Map<String, dynamic>>()) {
      ops.add(op);
      switch (op['op']) {
        case 'open':
          final id = 'w${++seq}';
          windows.add({
            'id': id,
            'tool': op['tool'],
            'name': op['title'] ?? op['tool'],
            'title': op['title'] ?? '',
            'x': 16,
            'y': 16,
            'w': 300,
            'h': 240,
            'z': windows.length + 1,
          });
          ids.add(id);
        case 'move':
          final w = windows.firstWhere((w) => w['id'] == op['id']);
          w
            ..['x'] = op['x']
            ..['y'] = op['y']
            ..['w'] = op['w']
            ..['h'] = op['h'];
          ids.add(op['id'] as String);
        case 'close':
          windows.removeWhere((w) => w['id'] == op['id']);
          ids.add(op['id'] as String);
        case 'close_tool':
          windows.removeWhere((w) => w['tool'] == op['tool']);
          ids.add('');
        case 'pin':
          final w = windows.firstWhere((w) => w['id'] == op['id']);
          pins.add({...w, 'id': 'p${++seq}'});
          ids.add('p$seq');
        case 'unpin':
          pins.removeWhere((p) => p['id'] == op['id']);
          ids.add(op['id'] as String);
        default:
          ids.add('');
      }
    }
    if (ops.last['op'] != 'viewport') version++;
    return {'desktop': desk, 'ids': ids};
  });
}

Map<String, dynamic> _window(
  String id,
  String tool,
  String name,
  double x,
  double y, {
  String title = '',
  int z = 1,
}) => {
  'id': id,
  'tool': tool,
  'name': name,
  'title': title,
  'x': x,
  'y': y,
  'w': 320,
  'h': 260,
  'z': z,
  'microtool': 'report',
  'args': {'city': id},
};

void main() {
  group('desk controller', () {
    test('opens, moves, closes a tool at once, pins, focuses', () async {
      final node = _Node([
        _window('a', 'wx', 'Weather', 16, 16),
        _window('b', 'wx', 'Weather', 360, 16, z: 2),
        _window('c', 'mk', 'Markets', 16, 300, z: 3),
      ]);
      final c = DeskController(node.api, pollEvery: const Duration(hours: 1));
      c.attach('s1', 'r1');
      await c.refresh(force: true);
      expect(c.state.windows, hasLength(3));
      expect(c.state.openTools.map((t) => (t.$1, t.$3)), [
        ('wx', 2),
        ('mk', 1),
      ]);

      await c.move('a', const Rect.fromLTWH(100, 120, 400, 300));
      expect(node.ops.last, {
        'op': 'move',
        'id': 'a',
        'x': 100.0,
        'y': 120.0,
        'w': 400.0,
        'h': 300.0,
      });
      expect(c.state.windows.firstWhere((w) => w.id == 'a').rect.left, 100);

      c.focusOn('wx');
      expect(c.focusTool, 'wx');
      c.focusOn('wx');
      expect(c.focusTool, isNull, reason: 'the same tool again shows all');

      c.minimize('a');
      expect(c.isMinimized('a'), isTrue);
      expect(c.state.windows.map((w) => w.id), [
        'a',
        'b',
        'c',
      ], reason: 'minimize keeps the window open on the node');
      c.focusOn('wx');
      expect(
        c.isMinimized('a'),
        isFalse,
        reason: 'the dock restores that tool’s minimized windows',
      );
      expect(
        c.focusTool,
        isNull,
        reason: 'restoring does not gather the windows or lock dragging',
      );
      c.focusOn('wx');
      expect(c.focusTool, 'wx');
      c.minimize('a');
      c.focusOn('wx');
      expect(
        c.focusTool,
        isNull,
        reason: 'restoring a minimized window leaves it draggable',
      );
      expect(c.isPresented('a'), isTrue);
      c.restore('a'); // already restored by focusOn
      expect(c.isMinimized('a'), isFalse);

      await c.togglePin(c.state.windows.firstWhere((w) => w.id == 'c'));
      expect(c.state.pins, hasLength(1));
      expect(
        c.isPinned(c.state.windows.firstWhere((w) => w.id == 'c')),
        isTrue,
      );

      c.focusOn('wx');
      await c.closeTool('wx');
      expect(node.ops.last, {'op': 'close_tool', 'tool': 'wx'});
      expect(c.state.windows.map((w) => w.id), ['c']);
      expect(
        c.focusTool,
        isNull,
        reason: 'closing the focused tool shows the rest',
      );

      final id = await c.openPin(c.state.pins.single);
      expect(id, isNotNull);
      expect(node.ops.last['op'], 'open');
      c.dispose();
    });

    test('reports the size of the desk once it settles', () async {
      final node = _Node(const []);
      final c = DeskController(node.api, pollEvery: const Duration(hours: 1));
      c.attach('s1', 'home');
      c.reportViewport(const Size(1000, 700));
      c.reportViewport(const Size(1003, 702)); // still settling
      await Future<void>.delayed(const Duration(milliseconds: 800));
      c.reportViewport(const Size(1005, 704)); // noise after it settled
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(node.ops.where((o) => o['op'] == 'viewport').toList(), [
        {'op': 'viewport', 'w': 1003.0, 'h': 702.0},
      ]);
      c.dispose();
    });
  });

  group('floating desk', () {
    Future<(DeskController, _Node)> pump(
      WidgetTester tester,
      _Node node,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = DeskController(node.api, pollEvery: const Duration(hours: 1));
      c.attach('s1', 'r1');
      await tester.runAsync(() => c.refresh(force: true));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingDesk(
              controller: c,
              windowContent: (context, w) =>
                  Center(child: Text('content of ${w.id}')),
              pinPreview: (p) => Text('preview of ${p.label}'),
              emptyState: const Center(child: Text('empty desk')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Let the viewport report go out.
      await tester.pump(const Duration(seconds: 1));
      return (c, node);
    }

    testWidgets(
      'windows float where the desk keeps them; the dock lists their tools',
      (tester) async {
        final (c, _) = await pump(
          tester,
          _Node([
            _window('a', 'wx', 'Weather', 40, 40, title: 'Weather · New York'),
            _window('c', 'mk', 'Markets', 420, 60, title: 'Markets', z: 2),
          ]),
        );
        expect(find.text('content of a'), findsOneWidget);
        expect(find.text('content of c'), findsOneWidget);
        expect(find.text('Weather · New York'), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('a'))),
          const Offset(40, 40),
        );
        expect(find.byTooltip('Weather · 1 window'), findsOneWidget);
        expect(find.byTooltip('Markets · 1 window'), findsOneWidget);
        expect(find.text('empty desk'), findsNothing);
        c.dispose();
      },
    );

    testWidgets(
      'a dock tool gathers its windows alone; Show all brings everything back',
      (tester) async {
        final (c, _) = await pump(
          tester,
          _Node([
            _window('a', 'wx', 'Weather', 700, 400),
            _window('b', 'wx', 'Weather', 760, 420, z: 2),
            _window('c', 'mk', 'Markets', 40, 40, z: 3),
          ]),
        );
        await tester.tap(find.byTooltip('Weather · 2 windows'));
        await tester.pumpAndSettle();
        expect(c.focusTool, 'wx');
        expect(find.text('Only Weather'), findsOneWidget);
        // Markets is hidden (into the dock); the weather windows are side by side.
        final hidden = tester.widget<IgnorePointer>(
          find
              .ancestor(
                of: find.text('content of c'),
                matching: find.byType(IgnorePointer),
              )
              .first,
        );
        expect(hidden.ignoring, isTrue);
        final a = tester.getRect(find.byKey(const ValueKey('a')));
        final b = tester.getRect(find.byKey(const ValueKey('b')));
        expect(a.overlaps(b), isFalse);
        await tester.tap(find.text('Show all'));
        await tester.pumpAndSettle();
        expect(c.focusTool, isNull);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('a'))),
          const Offset(700, 400),
          reason: 'back where it was',
        );
        c.dispose();
      },
    );

    testWidgets('minimize hides a window to the dock without closing it', (
      tester,
    ) async {
      final (c, node) = await pump(
        tester,
        _Node([
          _window('a', 'wx', 'Weather', 40, 40, title: 'Weather'),
          _window('c', 'mk', 'Markets', 560, 40, title: 'Markets', z: 2),
        ]),
      );
      expect(windowChrome('Minimize'), findsNWidgets(2));
      await tester.tap(find.byIcon(Icons.minimize_rounded).last);
      await tester.pumpAndSettle();
      expect(c.isMinimized('c'), isTrue);
      expect(c.state.windows.map((w) => w.id), ['a', 'c']);
      expect(node.ops.where((o) => o['op'] == 'close'), isEmpty);
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.text('content of c'),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isTrue,
      );
      await tester.tap(find.byTooltip('Markets · 1 window'));
      await tester.pumpAndSettle();
      expect(c.isMinimized('c'), isFalse);
      expect(c.focusTool, isNull);
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.text('content of c'),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isFalse,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('c'))),
        const Offset(560, 40),
        reason: 'the window comes back where it was',
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Markets').first),
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(18, 12));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      final moved = tester.getTopLeft(find.byKey(const ValueKey('c')));
      expect(moved.dx, greaterThan(560));
      expect(moved.dy, greaterThan(40));
      c.dispose();
    });

    testWidgets('a tool closes all its windows from the dock in one action', (
      tester,
    ) async {
      final (c, node) = await pump(
        tester,
        _Node([
          _window('a', 'wx', 'Weather', 40, 40),
          _window('b', 'wx', 'Weather', 400, 40, z: 2),
          _window('c', 'mk', 'Markets', 40, 340, z: 3),
        ]),
      );
      final dockItem = find.byTooltip('Weather · 2 windows');
      await tester.longPress(dockItem);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close 2 windows'));
      await tester.pumpAndSettle();
      expect(node.ops.last, {'op': 'close_tool', 'tool': 'wx'});
      expect(c.state.windows.map((w) => w.id), ['c']);
      expect(find.text('content of a'), findsNothing);
      c.dispose();
    });

    testWidgets('dragging a window by its title bar moves it on the desk', (
      tester,
    ) async {
      final (c, node) = await pump(
        tester,
        _Node([_window('a', 'wx', 'Weather', 40, 40, title: 'Weather')]),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Weather').first),
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(20, 10));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      final move = node.ops.lastWhere((o) => o['op'] == 'move');
      expect(move['id'], 'a');
      expect((move['x'] as num) > 200, isTrue);
      expect((move['y'] as num) > 100, isTrue);
      c.dispose();
    });

    testWidgets('only presented windows float; a new one opens itself', (
      tester,
    ) async {
      final (c, _) = await pump(
        tester,
        _Node([
          _window('a', 'wx', 'Weather', 40, 40),
          _window('c', 'mk', 'Markets', 420, 60, z: 2),
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingDesk(
              controller: c,
              onlyPresented: true,
              captureSurface: false,
              showDock: false,
              windowContent: (context, w) => Text('content of ${w.id}'),
              pinPreview: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('content of a'), findsNothing);
      expect(find.text('content of c'), findsNothing);

      c.present('a');
      await tester.pumpAndSettle();
      expect(find.text('content of a'), findsOneWidget);
      expect(find.text('content of c'), findsNothing);

      await c.open('mk', title: 'Markets');
      await tester.pumpAndSettle();
      expect(find.textContaining('content of w'), findsOneWidget);
      c.dispose();
    });

    testWidgets(
      'closing or minimizing a floated card leaves the desk widget',
      (tester) async {
        final (c, node) = await pump(
          tester,
          _Node([
            _window('a', 'wx', 'Weather', 40, 40),
            _window('c', 'mk', 'Markets', 420, 60, z: 2),
          ]),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FloatingDesk(
                controller: c,
                onlyPresented: true,
                captureSurface: false,
                showDock: false,
                windowContent: (context, w) => Text('content of ${w.id}'),
                pinPreview: (_) => const SizedBox.shrink(),
              ),
            ),
          ),
        );
        c.present('a');
        await tester.pumpAndSettle();
        await tester.tap(windowChrome('Close'));
        await tester.pumpAndSettle();
        expect(find.text('content of a'), findsNothing);
        expect(c.isPresented('a'), isFalse);
        expect(c.isMinimized('a'), isFalse);
        expect(c.state.windows.map((w) => w.id), contains('a'));
        expect(node.ops.where((o) => o['op'] == 'close'), isEmpty);

        c.present('a');
        await tester.pumpAndSettle();
        await tester.tap(windowChrome('Minimize'));
        await tester.pumpAndSettle();
        expect(find.text('content of a'), findsNothing);
        expect(c.isPresented('a'), isFalse);
        expect(c.isMinimized('a'), isTrue);
        expect(c.state.windows.map((w) => w.id), contains('a'));
        expect(node.ops.where((o) => o['op'] == 'close'), isEmpty);

        c.focusOn('wx');
        await tester.pumpAndSettle();
        expect(c.isMinimized('a'), isFalse);
        expect(c.isPresented('a'), isTrue);
        expect(c.focusTool, isNull);
        expect(find.text('content of a'), findsOneWidget);
        final before = tester.getTopLeft(find.byKey(const ValueKey('a')));
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Weather').first),
          kind: PointerDeviceKind.mouse,
        );
        for (var i = 0; i < 8; i++) {
          await gesture.moveBy(const Offset(16, 10));
          await tester.pump();
        }
        await gesture.up();
        await tester.pumpAndSettle();
        final after = tester.getTopLeft(find.byKey(const ValueKey('a')));
        expect(after.dx, greaterThan(before.dx));
        expect(after.dy, greaterThan(before.dy));
        c.dispose();
      },
    );

    testWidgets('the pinned desk shows pinned windows and opens them again', (
      tester,
    ) async {
      final (c, node) = await pump(
        tester,
        _Node(
          const [],
          pins: [
            {
              'id': 'p1',
              'tool': 'wx',
              'name': 'Weather',
              'title': 'Weather · Paris',
              'w': 400,
              'h': 500,
              'microtool': 'report',
              'args': {'city': 'Paris'},
            },
          ],
        ),
      );
      expect(find.text('empty desk'), findsOneWidget);
      await tester.tap(find.byTooltip('Pinned desk'));
      await tester.pumpAndSettle();
      expect(find.text('Weather · Paris'), findsOneWidget);
      expect(find.text('preview of Weather · Paris'), findsOneWidget);
      await tester.tap(find.text('Open on desk'));
      await tester.pumpAndSettle();
      final open = node.ops.lastWhere((o) => o['op'] == 'open');
      expect(open['args'], {'city': 'Paris'});
      expect(c.pinnedOpen, isFalse);
      c.dispose();
    });

    testWidgets(
      'what agents change on the desk moves, closes and opens with animation',
      (tester) async {
        final (c, node) = await pump(
          tester,
          _Node([
            _window('a', 'wx', 'Weather', 40, 40),
            _window('b', 'mk', 'Markets', 420, 40, z: 2),
          ]),
        );
        Offset at(String id) => tester.getTopLeft(find.byKey(ValueKey(id)));
        Future<void> agent(void Function() change) async {
          change();
          node.version++;
          await c.refresh(force: true);
          await tester.pump();
        }

        // An agent moves a window: it glides there.
        await agent(
          () => node.windows.first
            ..['x'] = 640
            ..['y'] = 200,
        );
        await tester.pump(const Duration(milliseconds: 200));
        final mid = at('a');
        expect(mid.dx > 40 && mid.dx < 640, isTrue, reason: 'on its way: $mid');
        await tester.pumpAndSettle();
        expect(at('a'), const Offset(640, 200));

        // An agent closes one: it fades out, then is gone.
        await agent(() => node.windows.removeWhere((w) => w['id'] == 'b'));
        expect(
          find.text('content of b'),
          findsOneWidget,
          reason: 'still fading',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.text('content of b'), findsNothing);

        // An agent opens one below the fold: the desk glides down to it.
        await agent(
          () => node.windows.add(_window('c', 'mk', 'Markets', 60, 1400, z: 3)),
        );
        await tester.pumpAndSettle();
        final c3 = tester.getRect(find.byKey(const ValueKey('c')));
        expect(
          c3.top >= 0 && c3.bottom <= 800,
          isTrue,
          reason: 'scrolled into view: $c3',
        );
        c.dispose();
      },
    );

    testWidgets('hovering window chrome does not crash', (tester) async {
      final errors = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details.exception);
        previous?.call(details);
      };
      addTearDown(() => FlutterError.onError = previous);
      final node = _Node([
        _window('a', 'wx', 'Weather', 40, 40, title: 'Weather'),
      ]);
      final c = DeskController(node.api, pollEvery: const Duration(hours: 1));
      c.attach('s1', 'r1');
      await tester.runAsync(() => c.refresh(force: true));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromPack(DefaultThemePacks.paper, Brightness.light),
          home: Scaffold(
            body: OverlayPortal(
              controller: OverlayPortalController()..show(),
              overlayLocation: OverlayChildLocation.rootOverlay,
              overlayChildBuilder: (context) => Overlay.wrap(
                child: FloatingDesk(
                  controller: c,
                  captureSurface: false,
                  onlyPresented: true,
                  showDock: false,
                  windowContent: (context, w) => Text('content of ${w.id}'),
                  pinPreview: (_) => const SizedBox.shrink(),
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      c.present('a');
      await tester.pumpAndSettle();
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      for (final tip in ['Minimize', 'Maximize', 'Close', 'Pin to the pinned desk']) {
        final box = tester.getRect(windowChrome(tip));
        await gesture.moveTo(box.topLeft + const Offset(2, 2));
        await tester.pump();
        await gesture.moveTo(box.center);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('content of a'), findsOneWidget);
        await gesture.moveTo(const Offset(4, 4));
        await tester.pump();
      }
      expect(errors, isEmpty);
      c.dispose();
    });
  });
}
