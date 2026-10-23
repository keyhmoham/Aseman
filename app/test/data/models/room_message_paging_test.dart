import 'package:aseman/src/data/models/space.dart';
import 'package:flutter_test/flutter_test.dart';

RoomMessage _msg(String id, DateTime at, [String body = '']) => RoomMessage(
      id: id,
      spaceId: 's',
      roomId: 'r',
      senderId: 'u',
      body: body.isEmpty ? id : body,
      createdAt: at,
    );

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);
  final t1 = t0.add(const Duration(minutes: 1));
  final t2 = t0.add(const Duration(minutes: 2));
  final t3 = t0.add(const Duration(minutes: 3));
  final t4 = t0.add(const Duration(minutes: 4));

  test('mergeNewestRoomMessages keeps older pages and refreshes the window',
      () {
    final held = [_msg('a', t0), _msg('b', t1), _msg('c', t2), _msg('d', t3)];
    // Newest page of 2, with an edit to d and a new e.
    final page = [_msg('e', t4), _msg('d', t3, 'edited')];
    final merged = mergeNewestRoomMessages(held, page);
    expect(merged.map((m) => m.id).toList(), ['a', 'b', 'c', 'd', 'e']);
    expect(merged[3].body, 'edited');
  });

  test('mergeNewestRoomMessages drops a deleted message in the newest window',
      () {
    final held = [_msg('c', t2), _msg('d', t3), _msg('e', t4)];
    final page = [_msg('e', t4), _msg('c', t2)]; // d deleted
    final merged = mergeNewestRoomMessages(held, page);
    expect(merged.map((m) => m.id).toList(), ['c', 'e']);
  });

  test('mergeOlderRoomMessages prepends without duplicating', () {
    final held = [_msg('c', t2), _msg('d', t3)];
    final older = [_msg('b', t1), _msg('a', t0), _msg('c', t2)];
    final merged = mergeOlderRoomMessages(held, older);
    expect(merged.map((m) => m.id).toList(), ['a', 'b', 'c', 'd']);
  });
}
