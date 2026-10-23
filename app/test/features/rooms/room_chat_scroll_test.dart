import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/features/rooms/presentation/room_chat_scroll.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/room_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RoomMessage _msg(String id, String body) => RoomMessage(
      id: id,
      spaceId: 'space-1',
      roomId: 'room-1',
      senderId: 'u1',
      body: body,
      createdAt: DateTime.utc(2026, 1, 1, 12, int.tryParse(id) ?? 0),
    );

List<RoomMessage> _many() => [
      for (var i = 0; i < 40; i++)
        _msg('$i', 'Message number $i — enough text to force a tall list.'),
    ];

Future<ScrollController?> _controllerOf(WidgetTester tester) async {
  final list = tester.widget<ListView>(find.byType(ListView).first);
  return list.controller;
}

Future<void> _open(WidgetTester tester, List<RoomMessage> messages) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 400,
        child: RoomChat(
          room: 'general',
          messages: messages,
          spaceId: 'space-1',
          roomId: 'room-1',
          bare: true,
        ),
      ),
    ),
  ));
  // Restore waits for a stable maxScrollExtent across frames.
  await tester.pumpAndSettle();
  await tester.pump();
  await tester.pump();
}

void main() {
  tearDown(RoomChatScrollStore.reset);

  test('offsetFor scales only when the list extent changed a lot', () {
    const saved = RoomChatScroll(offset: 200, nearBottom: false, maxExtent: 400);
    expect(saved.offsetFor(800), closeTo(400, 0.1));
    expect(saved.offsetFor(200), closeTo(100, 0.1));
    // Small jitter keeps the raw offset.
    expect(saved.offsetFor(420), closeTo(200, 0.1));
    expect(saved.offsetFor(400), closeTo(200, 0.1));
    const bottom = RoomChatScroll(offset: 100, nearBottom: true, maxExtent: 400);
    expect(bottom.offsetFor(900), 900);
  });

  testWidgets('leaving and returning restores the vertical scroll position',
      (tester) async {
    final messages = _many();
    await _open(tester, messages);
    final first = await _controllerOf(tester);
    expect(first, isNotNull);
    expect(first!.hasClients, isTrue);
    // Scroll up into history, away from the live bottom.
    final target = (first.position.maxScrollExtent * 0.35).clamp(0.0, 400.0);
    first.jumpTo(target);
    await tester.pumpAndSettle();
    expect(first.offset, closeTo(target, 1));

    // Leave the chat (another section / page): the list is disposed.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // Come back: the same offset must be restored after layout settles.
    await _open(tester, messages);
    final again = await _controllerOf(tester);
    expect(again, isNotNull);
    expect(again!.offset, closeTo(target, 1));
  });

  testWidgets('a first visit lands at the bottom of the conversation',
      (tester) async {
    await _open(tester, _many());
    final scroll = await _controllerOf(tester);
    expect(scroll, isNotNull);
    expect(scroll!.offset, closeTo(scroll.position.maxScrollExtent, 1));
  });

  testWidgets('saved near-bottom returns to the live end', (tester) async {
    final messages = _many();
    await _open(tester, messages);
    final first = await _controllerOf(tester);
    expect(first, isNotNull);
    first!.jumpTo(first.position.maxScrollExtent);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await _open(tester, messages);
    final again = await _controllerOf(tester);
    expect(again, isNotNull);
    expect(again!.offset, closeTo(again.position.maxScrollExtent, 1));
  });
}
