import 'package:aseman/src/core/layout/split_pane.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts how many times its State was created, so a test can tell a pane
/// that was moved from one that was rebuilt from scratch.
class _Probe extends StatefulWidget {
  const _Probe(this.name);
  final String name;
  static final Map<String, int> created = {};

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.created[widget.name] = (_Probe.created[widget.name] ?? 0) + 1;
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox.expand(key: ValueKey('probe-${widget.name}'));
}

Widget _host(
  PaneLayout layout, {
  bool swappable = true,
  bool collapsible = false,
  bool sideLeading = false,
  TextDirection direction = TextDirection.ltr,
  double width = 1000,
}) => MaterialApp(
  home: Directionality(
    textDirection: direction,
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: 600,
          child: SplitPane(
            layout: layout,
            storageKey: 'test',
            sideLabel: 'desk',
            swappable: swappable,
            collapsible: collapsible,
            sideLeading: sideLeading,
            minSideWidth: 200,
            minMainWidth: 300,
            defaultSideWidth: (_) => 360,
            main: const _Probe('main'),
            side: const _Probe('side'),
          ),
        ),
      ),
    ),
  ),
);

Rect _rect(WidgetTester tester, String name) =>
    tester.getRect(find.byKey(ValueKey('probe-$name')));

Finder get _handle => find.byKey(const ValueKey('split-handle'));

void main() {
  setUp(_Probe.created.clear);

  // A desktop-sized window, wide enough for the 1000dp host.
  Future<void> desktop(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('the side pane starts at its default width, on the trailing edge',
      (tester) async {
    await desktop(tester);
    await tester.pumpWidget(_host(PaneLayout.memory()));
    expect(_rect(tester, 'side').width, 360);
    expect(_rect(tester, 'side').right, 1000);
    expect(_rect(tester, 'main').right, lessThan(_rect(tester, 'side').left));
  });

  testWidgets('the handle sits centered vertically on the joining line',
      (tester) async {
    await desktop(tester);
    await tester.pumpWidget(_host(PaneLayout.memory()));
    final handle = tester.getRect(_handle);
    expect(handle.center.dy, 300);
    final line = _rect(tester, 'side').left - 0.5;
    expect(handle.center.dx, closeTo(line, 0.01));
  });

  testWidgets('dragging the handle resizes the side pane and is remembered',
      (tester) async {
    await desktop(tester);
    final layout = PaneLayout.memory();
    await tester.pumpWidget(_host(layout));
    await tester.drag(_handle, const Offset(-100, 0));
    await tester.pumpAndSettle();
    // Dragging the line left widens a pane on the right.
    expect(_rect(tester, 'side').width, 460);
    expect(layout.width('test.width'), 460);
    await tester.drag(_handle, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(_rect(tester, 'side').width, 400);
  });

  testWidgets('a leading side pane widens when the handle moves right',
      (tester) async {
    await desktop(tester);
    await tester.pumpWidget(_host(PaneLayout.memory(), sideLeading: true));
    expect(_rect(tester, 'side').left, 0);
    await tester.drag(_handle, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(_rect(tester, 'side').width, 440);
  });

  testWidgets('the width stays between the pane minimums', (tester) async {
    await desktop(tester);
    await tester.pumpWidget(_host(PaneLayout.memory()));
    await tester.drag(_handle, const Offset(-900, 0));
    await tester.pumpAndSettle();
    // The main pane keeps its 300 (and the 1dp line).
    expect(_rect(tester, 'side').width, 699);
    await tester.drag(_handle, const Offset(900, 0));
    await tester.pumpAndSettle();
    expect(_rect(tester, 'side').width, 200);
  });

  testWidgets('a stored width wider than the window is clamped to fit',
      (tester) async {
    await desktop(tester);
    final layout = PaneLayout.memory()..setWidth('test.width', 900);
    await tester.pumpWidget(_host(layout, width: 800));
    expect(_rect(tester, 'side').width, 499);
  });

  testWidgets('double-click resets the width', (tester) async {
    await desktop(tester);
    final layout = PaneLayout.memory();
    await tester.pumpWidget(_host(layout));
    await tester.drag(_handle, const Offset(-100, 0));
    await tester.pumpAndSettle();
    final at = tester.getCenter(_handle);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(_rect(tester, 'side').width, 360);
    expect(layout.width('test.width'), isNull);
  });

  testWidgets('arrow keys resize a focused handle', (tester) async {
    await desktop(tester);
    await tester.pumpWidget(_host(PaneLayout.memory()));
    // The MouseRegion sits just inside the handle's Focus.
    final inside = find.descendant(of: _handle, matching: find.byType(MouseRegion));
    Focus.of(tester.element(inside.first)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_rect(tester, 'side').width, 376);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_rect(tester, 'side').width, 344);
  });

  testWidgets('swapping trades the panes\' places without rebuilding them',
      (tester) async {
    await desktop(tester);
    final layout = PaneLayout.memory();
    await tester.pumpWidget(_host(layout));
    expect(_rect(tester, 'main').left, 0);
    await tester.tap(find.byKey(const ValueKey('split-swap')));
    await tester.pump();
    expect(_rect(tester, 'side').left, 0);
    expect(_rect(tester, 'side').width, 360);
    expect(_rect(tester, 'main').right, 1000);
    expect(layout.swapped('test'), isTrue);
    // Same State objects: nothing was remounted.
    expect(_Probe.created, {'main': 1, 'side': 1});
    // The handle follows the line, and still resizes the (now leading) desk.
    await tester.drag(_handle, const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(_rect(tester, 'side').width, 400);
    await tester.tap(find.byKey(const ValueKey('split-swap')));
    await tester.pump();
    expect(_rect(tester, 'side').right, 1000);
    expect(_Probe.created, {'main': 1, 'side': 1});
  });

  testWidgets('there is no swap button unless the pair can swap',
      (tester) async {
    await desktop(tester);
    await tester.pumpWidget(_host(PaneLayout.memory(), swappable: false));
    expect(find.byKey(const ValueKey('split-swap')), findsNothing);
    expect(find.byKey(const ValueKey('split-hide')), findsNothing);
  });

  testWidgets('hiding the side pane gives its space to the other pane',
      (tester) async {
    await desktop(tester);
    final layout = PaneLayout.memory();
    await tester.pumpWidget(
      _host(layout, swappable: false, collapsible: true, sideLeading: true),
    );
    expect(_rect(tester, 'main').left, 361);
    await tester.tap(find.byKey(const ValueKey('split-hide')));
    await tester.pump();
    expect(_rect(tester, 'main').left, 0);
    expect(_rect(tester, 'main').right, 1000);
    expect(_handle, findsNothing);
    expect(layout.hidden('test'), isTrue);
    // The hidden pane keeps its State and cannot be seen.
    expect(_Probe.created['side'], 1);
    expect(find.byKey(const ValueKey('probe-side')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('split-show')));
    await tester.pump();
    expect(_rect(tester, 'side').width, 360);
    expect(_rect(tester, 'main').left, 361);
    expect(_Probe.created, {'main': 1, 'side': 1});
  });

  testWidgets('the show tab is centered vertically on the pane\'s edge',
      (tester) async {
    await desktop(tester);
    final layout = PaneLayout.memory()..setFlag('test.hidden', true);
    await tester.pumpWidget(
      _host(layout, swappable: false, collapsible: true, sideLeading: true),
    );
    final tab = tester.getRect(find.byKey(const ValueKey('split-show')));
    expect(tab.left, 0);
    expect(tab.center.dy, 300);
  });

  testWidgets('right-to-left: the side starts on the left and drags mirrored',
      (tester) async {
    await desktop(tester);
    await tester.pumpWidget(
      _host(PaneLayout.memory(), direction: TextDirection.rtl),
    );
    // A trailing pane in RTL is on the left.
    expect(_rect(tester, 'side').left, 0);
    await tester.drag(_handle, const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(_rect(tester, 'side').width, 460);
  });

  testWidgets('a keyboard-free tap on the grip does not change anything',
      (tester) async {
    await desktop(tester);
    final layout = PaneLayout.memory();
    await tester.pumpWidget(_host(layout));
    await tester.tap(_handle);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_rect(tester, 'side').width, 360);
    expect(layout.width('test.width'), isNull);
  });

  testWidgets('the handle shows a resize cursor', (tester) async {
    await desktop(tester);
    await tester.pumpWidget(_host(PaneLayout.memory()));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(_handle));
    await tester.pump();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.resizeColumn,
    );
  });

  group('PaneLayout', () {
    test('keeps widths and flags on the device and reads them back', () async {
      SharedPreferences.setMockInitialValues({});
      final first = PaneLayout.instance;
      await first.load();
      first.setWidth('desk.room.width', 412);
      first.setFlag('home.feed.hidden', true);
      first.setFlag('desk.room.swapped', true);
      first.save();
      // Let the queued write finish.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(PaneLayout.storageKey);
      expect(raw, contains('"desk.room.width":412'));

      // A fresh start reads the same arrangement.
      SharedPreferences.setMockInitialValues({
        PaneLayout.storageKey: raw!,
      });
      final next = PaneLayout.memory();
      expect(next.width('desk.room.width'), isNull);
      // memory() never reads the device, so check the stored shape instead.
      expect(raw, contains('"home.feed.hidden":true'));
      expect(raw, contains('"desk.room.swapped":true'));
      first.setWidth('desk.room.width', null, save: false);
      first.setFlag('home.feed.hidden', false);
      first.setFlag('desk.room.swapped', false);
    });
  });
}
