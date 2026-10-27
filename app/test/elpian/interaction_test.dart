import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/elpian/elpian.dart';
import 'package:aseman/src/features/tools/ui_kit/kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What an Elpian program receives: the handler named in the tree (a
/// string, as a program writes it) for each event, in order, the way
/// ElpianVmWidget routes them to the VM (the global handler, by
/// `currentTarget`).
class Routed {
  Routed(this.engine) {
    engine.setGlobalEventHandler((event) {
      final id = event.currentTarget?.toString();
      if (id == null) return;
      final handler = engine.eventDispatcher.getNode(id)?.events?[event.type];
      if (handler is String) calls.add(handler);
      if (handler is String) events.add(event);
    });
  }
  final ElpianEngine engine;
  final calls = <String>[];
  final events = <ElpianEvent>[];
}

Future<void> pumpApp(WidgetTester tester, Widget child,
    {Size size = const Size(400, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light, home: child));
  await tester.pump();
}

Map<String, dynamic> navApp(int tab) => {
      'type': 'Scaffold',
      'children': [
        {
          'type': 'ListView',
          'children': [
            {
              'type': 'Text',
              'props': {'text': 'Screen $tab'}
            },
          ],
        },
        {
          'type': 'NavigationBar',
          'props': {
            'selected': tab,
            'items': [
              {'icon': 'home', 'label': 'Home'},
              {'icon': 'search', 'label': 'Search'},
              {'icon': 'settings', 'label': 'Settings'},
            ],
          },
          'events': {'change': '__app0_tab'},
        },
      ],
    };

void main() {
  testWidgets('two running apps each get their own taps', (tester) async {
    // A phone's board draws the app's widget while the app is open in
    // full: two VMs of the same program, with the same handler names.
    final full = Routed(kitEngine());
    final tile = Routed(kitEngine());
    await pumpApp(
        tester,
        Column(children: [
          Expanded(child: full.engine.renderFromJson(navApp(0))),
          SizedBox(
              height: 200, child: tile.engine.renderFromJson(navApp(0))),
        ]));
    await tester.tap(find.text('Search').first);
    await tester.pump();
    expect(full.calls, ['__app0_tab'], reason: 'the open app runs the tap');
    expect(tile.calls, isEmpty, reason: 'the other app must not see it');
  });

  testWidgets('a NavigationBar sends the destination tapped', (tester) async {
    final app = Routed(kitEngine());
    await pumpApp(tester, app.engine.renderFromJson(navApp(0)));
    await tester.tap(find.text('Settings'));
    await tester.pump();
    expect(app.calls, ['__app0_tab']);
    // What the program's handler reads: e.value (and e.data.value).
    final json = elpianEventJson(app.events.single);
    expect(json['value'], 2);
    expect(json['data'], {'value': 2});
    expect(json['type'], 'change');
  });

  test('event data reaches handlers at the top level, never replacing',
      () {
    final json = elpianEventJson(ElpianPointerEvent(
      type: 'drag',
      eventType: ElpianEventType.drag,
      target: 'board',
      position: const Offset(110, 220),
      localPosition: const Offset(10, 20),
      delta: const Offset(2, 3),
      data: const {'velocity': 5, 'type': 'not this'},
    ));
    expect(json['type'], 'drag');
    expect(json['localPosition'], {'x': 10.0, 'y': 20.0});
    expect(json['delta'], {'x': 2.0, 'y': 3.0});
    expect(json['velocity'], 5);
  });

  testWidgets('a keyed node keeps its events when its parent changes',
      (tester) async {
    final app = Routed(kitEngine());
    Map<String, dynamic> tree(String parent) => {
          'type': parent,
          'children': [
            {
              'type': 'Container',
              'key': 'go',
              'props': {
                'style': {'width': 80, 'height': 40}
              },
              'events': {'tap': 'go'},
              'children': [
                {
                  'type': 'Text',
                  'props': {'text': 'Go'}
                }
              ],
            },
          ],
        };
    final state = ValueNotifier(tree('Column'));
    await pumpApp(
        tester,
        Scaffold(
            body: ValueListenableBuilder(
                valueListenable: state,
                builder: (_, t, _) => app.engine.renderFromJson(t))));
    // A new parent type: Flutter builds a new subtree and disposes the old
    // one after the new one registered the same key.
    state.value = tree('Row');
    await tester.pump();
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(app.calls, ['go']);
  });

  testWidgets('drawing on a canvas in a scrolling page draws, not scrolls',
      (tester) async {
    final app = Routed(kitEngine());
    await pumpApp(
        tester,
        Scaffold(
          body: app.engine.renderFromJson({
            'type': 'ListView',
            'children': [
              {
                'type': 'SizedBox',
                'props': {
                  'style': {'height': 200}
                }
              },
              {
                'type': 'Canvas',
                'key': 'board',
                'props': {'height': 300, 'backgroundColor': '#ffffff'},
                'events': {
                  'dragstart': 'penDown',
                  'drag': 'penMove',
                  'dragend': 'penUp'
                },
              },
              {
                'type': 'SizedBox',
                'props': {
                  'style': {'height': 1200}
                }
              },
            ],
          }),
        ));
    final board = find.byKey(const ValueKey('board'));
    final before = tester.getTopLeft(board);
    // A vertical stroke: exactly what a scroll view takes for itself.
    await tester.dragFrom(tester.getCenter(board), const Offset(0, -120));
    await tester.pump();
    expect(tester.getTopLeft(board), before, reason: 'the page must not scroll');
    expect(app.calls.first, 'penDown');
    expect(app.calls, contains('penMove'));
    expect(app.calls.last, 'penUp');
    // Points are where the finger is on the canvas.
    final move = app.events.firstWhere((e) => e.type == 'drag');
    expect(move, isA<ElpianPointerEvent>());
    final local = (move as ElpianPointerEvent).localPosition;
    expect(local.dy, inInclusiveRange(0, 300));
  });

  testWidgets('pointer events on a canvas in a scroll keep the page still',
      (tester) async {
    final app = Routed(kitEngine());
    await pumpApp(
        tester,
        Scaffold(
          body: app.engine.renderFromJson({
            'type': 'ListView',
            'children': [
              {
                'type': 'Canvas',
                'key': 'board',
                'props': {'height': 400},
                'events': {
                  'pointerdown': 'down',
                  'pointermove': 'move',
                  'pointerup': 'up'
                },
              },
              {
                'type': 'SizedBox',
                'props': {
                  'style': {'height': 1200}
                }
              },
            ],
          }),
        ));
    final board = find.byKey(const ValueKey('board'));
    final before = tester.getTopLeft(board);
    final g = await tester.startGesture(tester.getCenter(board));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, -20));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(tester.getTopLeft(board), before, reason: 'the page must not scroll');
    expect(app.calls.first, 'down');
    expect(app.calls.where((c) => c == 'move').length, greaterThan(3));
    expect(app.calls.last, 'up');
  });

  testWidgets('a pinch on a node reaches its scale events', (tester) async {
    final app = Routed(kitEngine());
    await pumpApp(
        tester,
        Scaffold(
          body: app.engine.renderFromJson({
            'type': 'Container',
            'key': 'map',
            'props': {
              'style': {'width': 300, 'height': 300, 'backgroundColor': '#eeeeee'}
            },
            'events': {'scalestart': 'zoomStart', 'scaleupdate': 'zoom'},
          }),
        ));
    final c = tester.getCenter(find.byKey(const ValueKey('map')));
    final a = await tester.startGesture(c - const Offset(20, 0), pointer: 1);
    final b = await tester.startGesture(c + const Offset(20, 0), pointer: 2);
    for (var i = 0; i < 5; i++) {
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(app.calls, contains('zoomStart'));
    expect(app.calls, contains('zoom'));
  });

  testWidgets('a tap on a button inside a tappable card runs only the button',
      (tester) async {
    final app = Routed(kitEngine());
    await pumpApp(
        tester,
        Scaffold(
          body: app.engine.renderFromJson({
            'type': 'Container',
            'key': 'row',
            'props': {
              'style': {'padding': 16, 'backgroundColor': '#eeeeee'}
            },
            'events': {'tap': 'openRow'},
            'children': [
              {
                'type': 'Button',
                'key': 'del',
                'props': {'text': 'Delete'},
                'events': {'tap': 'deleteRow'},
              },
            ],
          }),
        ));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(app.calls, ['deleteRow']);
    await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('row'))) +
        const Offset(4, 4));
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.calls, ['deleteRow', 'openRow']);
  });

  testWidgets('a button inside a draggable surface still taps',
      (tester) async {
    final app = Routed(kitEngine());
    await pumpApp(
        tester,
        Scaffold(
          body: app.engine.renderFromJson({
            'type': 'Stack',
            'children': [
              {
                'type': 'Container',
                'key': 'board',
                'props': {
                  'style': {'width': 400, 'height': 600, 'backgroundColor': '#ffffff'}
                },
                'events': {'drag': 'pan', 'dragstart': 'panStart'},
              },
              {
                'type': 'Positioned',
                'props': {
                  'style': {'top': 8, 'left': 8}
                },
                'children': [
                  {
                    'type': 'IconButton',
                    'key': 'undo',
                    'props': {'icon': 'undo', 'tooltip': 'Undo'},
                    'events': {'tap': 'undo'},
                  }
                ],
              },
            ],
          }),
        ));
    await tester.tap(find.byKey(const ValueKey('undo')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.calls, ['undo']);
  });

  testWidgets('a horizontal swipe on a node in a vertical list is a swipe',
      (tester) async {
    final app = Routed(kitEngine());
    await pumpApp(
        tester,
        Scaffold(
          body: app.engine.renderFromJson({
            'type': 'ListView',
            'children': [
              {
                'type': 'Container',
                'key': 'card',
                'props': {
                  'style': {'height': 120, 'backgroundColor': '#eeeeee'}
                },
                'events': {'swipeleft': 'next', 'swiperight': 'prev'},
              },
              {
                'type': 'SizedBox',
                'props': {
                  'style': {'height': 1200}
                }
              },
            ],
          }),
        ));
    await tester.fling(
        find.byKey(const ValueKey('card')), const Offset(-200, 0), 1000);
    await tester.pumpAndSettle();
    expect(app.calls, ['next']);
    // A vertical drag on it still scrolls the page.
    final before = tester.getTopLeft(find.byKey(const ValueKey('card')));
    await tester.drag(find.byKey(const ValueKey('card')), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const ValueKey('card'))).dy,
        lessThan(before.dy));
  });

  testWidgets('a fixed screen fills a phone: the canvas takes the free space',
      (tester) async {
    final app = Routed(kitEngine());
    final errors = <String>[];
    final old = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    addTearDown(() => FlutterError.onError = old);
    await pumpApp(
        tester,
        app.engine.renderFromJson({
          'type': 'Scaffold',
          'children': [
            {
              'type': 'Column',
              'props': {
                'style': {'alignItems': 'stretch'}
              },
              'children': [
                {
                  'type': 'Row',
                  'props': {
                    'style': {'padding': '12 16', 'gap': 8}
                  },
                  'children': [
                    {
                      'type': 'Expanded',
                      'children': [
                        {
                          'type': 'Text',
                          'props': {'text': 'Whiteboard', 'variant': 'headlineSmall'}
                        }
                      ]
                    },
                    {
                      'type': 'IconButton',
                      'key': 'undo',
                      'props': {'icon': 'undo', 'tooltip': 'Undo'},
                      'events': {'tap': 'undo'},
                    },
                  ],
                },
                {
                  'type': 'Expanded',
                  'children': [
                    {
                      'type': 'Canvas',
                      'key': 'board',
                      'events': {
                        'dragstart': 'down',
                        'drag': 'move',
                        'dragend': 'up',
                        'resize': 'size'
                      },
                    }
                  ],
                },
              ],
            },
            navApp(0)['children'][1],
          ],
        }),
        size: const Size(360, 640));
    await tester.pump();
    expect(errors, isEmpty);
    final board = tester.getRect(find.byKey(const ValueKey('board')));
    expect(board.width, 360);
    expect(board.height, greaterThan(400), reason: 'all the free height');
    // The program hears the size it was laid out at.
    final size = app.events.firstWhere((e) => e.type == 'resize');
    expect(size.data, {'width': 360.0, 'height': board.height});
    // Strokes arrive in the canvas's own coordinates.
    await tester.dragFrom(board.topLeft + const Offset(30, 40), const Offset(50, 60));
    await tester.pump();
    final down = app.events.firstWhere((e) => e.type == 'dragstart')
        as ElpianPointerEvent;
    expect(down.localPosition, const Offset(30, 40));
    await tester.tap(find.byKey(const ValueKey('undo')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.calls.last, 'undo');
  });

  testWidgets('mouse drags draw too', (tester) async {
    final app = Routed(kitEngine());
    await pumpApp(
        tester,
        Scaffold(
          body: app.engine.renderFromJson({
            'type': 'Canvas',
            'key': 'board',
            'props': {'width': 300, 'height': 300},
            'events': {'drag': 'penMove'},
          }),
        ));
    await tester.dragFrom(
        tester.getCenter(find.byKey(const ValueKey('board'))),
        const Offset(40, 40),
        kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(app.calls, contains('penMove'));
  });
}
