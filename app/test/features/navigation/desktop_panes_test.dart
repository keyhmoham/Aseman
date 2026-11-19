import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/layout/split_pane.dart';
import 'package:aseman/src/features/desk/presentation/compact_desk.dart';
import 'package:aseman/src/features/desk/presentation/free_desk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../fake_aseman_service.dart';

/// The desktop panes of the dashboard tabs: each pair of neighbors is joined
/// by one handle that resizes it, the chat/desk pairs can trade places, and
/// the Home feed and the Chats list can be put away.
void main() {
  final handles = find.byKey(const ValueKey('split-handle'));
  final swaps = find.byKey(const ValueKey('split-swap'));
  final hides = find.byKey(const ValueKey('split-hide'));
  final shows = find.byKey(const ValueKey('split-show'));
  // The inner pair's handle (chat | desk) is built before the outer one
  // (feed | assistant, list | detail) that contains it.
  final innerHandle = handles.first;
  final outerHandle = handles.last;

  setUp(() => PaneLayout.instance.reset());
  tearDown(() {
    PaneLayout.instance.reset();
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAllTestValues();
  });

  Future<void> openDesktop(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'aseman.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
          '"token":"x","private_key":"","public_key":"",'
          '"home_space_id":"00000000000000010000000000000002"}',
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(FakeAsemanService())),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openChats(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Chats'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Home: the feed and the assistant are joined by a handle, and '
      'the assistant\'s chat and desk by another', (tester) async {
    await openDesktop(tester);
    expect(handles, findsNWidgets(2));
    // Only the chat/desk pair swaps; only the feed can be hidden.
    expect(swaps, findsOneWidget);
    expect(hides, findsOneWidget);
    // Each handle is centered vertically on its joining line, in its pane.
    for (final handle in handles.evaluate()) {
      final box = tester.getRect(find.byWidget(handle.widget));
      expect(box.center.dy, closeTo(tester.getRect(outerHandle).center.dy, .01));
    }
  });

  testWidgets('Home: dragging the feed handle resizes the feed pane',
      (tester) async {
    await openDesktop(tester);
    final before = tester.getRect(outerHandle).center.dx;
    await tester.drag(outerHandle, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(outerHandle).center.dx, closeTo(before + 60, 1));
    expect(PaneLayout.instance.width('home.feed.width'), isNotNull);
  });

  testWidgets('Home: the feed can be hidden and shown; the assistant takes '
      'its space', (tester) async {
    await openDesktop(tester);
    // The assistant's own chat + desk pair is the inner SplitPane.
    final assistant = find.byType(SplitPane).last;
    final assistantBefore = tester.getSize(assistant).width;
    await tester.tap(hides);
    await tester.pumpAndSettle();
    expect(PaneLayout.instance.hidden('home.feed'), isTrue);
    expect(shows, findsOneWidget);
    // Only the assistant's own handle is left, and the assistant (chat and
    // desk) is wider by the room the feed gave up.
    expect(handles, findsOneWidget);
    expect(tester.getSize(assistant).width, greaterThan(assistantBefore));
    await tester.tap(shows);
    await tester.pumpAndSettle();
    expect(handles, findsNWidgets(2));
    expect(shows, findsNothing);
  });

  testWidgets('Home: the assistant\'s chat and desk can trade places',
      (tester) async {
    await openDesktop(tester);
    final deskOnRight = tester.getRect(innerHandle).center.dx;
    await tester.tap(swaps);
    await tester.pumpAndSettle();
    expect(PaneLayout.instance.swapped('desk.assistant'), isTrue);
    // The desk now leads: the line between the two moved to the left.
    expect(tester.getRect(innerHandle).center.dx, lessThan(deskOnRight));
    await tester.tap(swaps);
    await tester.pumpAndSettle();
    expect(PaneLayout.instance.swapped('desk.assistant'), isFalse);
    expect(tester.getRect(innerHandle).center.dx, closeTo(deskOnRight, 1));
  });

  testWidgets('Chats: the list can be resized and hidden', (tester) async {
    await openDesktop(tester);
    await openChats(tester);
    expect(handles, findsOneWidget);
    expect(hides, findsOneWidget);
    final before = tester.getRect(handles).center.dx;
    await tester.drag(handles, const Offset(-40, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(handles).center.dx, closeTo(before - 40, 1));

    await tester.tap(hides);
    await tester.pumpAndSettle();
    expect(PaneLayout.instance.hidden('chats.list'), isTrue);
    expect(handles, findsNothing);
    expect(shows, findsOneWidget);
    await tester.tap(shows);
    await tester.pumpAndSettle();
    expect(handles, findsOneWidget);
  });

  testWidgets('Chats: a room\'s chat and desk can trade places',
      (tester) async {
    await openDesktop(tester);
    await openChats(tester);
    await tester.tap(find.text('Atlas Collective').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('general').first);
    await tester.pumpAndSettle();
    // The list, and the room's chat and desk.
    expect(handles, findsNWidgets(2));
    final line = tester.getRect(innerHandle).center.dx;
    await tester.tap(swaps);
    await tester.pumpAndSettle();
    expect(PaneLayout.instance.swapped('desk.room'), isTrue);
    expect(tester.getRect(innerHandle).center.dx, lessThan(line));
  });

  testWidgets('Home: a desk widened past a small tablet becomes the free whiteboard',
      (tester) async {
    await openDesktop(tester);
    // At its default width the assistant's desk is the widget grid.
    expect(find.byType(FreeDesk), findsNothing);
    expect(find.byType(CompactDesk), findsOneWidget);
    await tester.drag(innerHandle, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FreeDesk)).width, greaterThanOrEqualTo(freeDeskWidth));
    expect(find.byType(CompactDesk), findsNothing);
    expect(find.byKey(const ValueKey('board-tool-note')), findsOneWidget);
    // Narrowed again, it is the grid once more.
    await tester.drag(innerHandle, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(find.byType(FreeDesk), findsNothing);
    expect(find.byType(CompactDesk), findsOneWidget);
  });
}
