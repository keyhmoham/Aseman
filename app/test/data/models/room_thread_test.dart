import 'package:aseman/src/data/models/space.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a thread reads its title, room and newest message', () {
    final t = RoomThread.fromJson({
      'id': 't1',
      'room_id': 'r1',
      'title': 'Pricing',
      'updated_at': '2026-10-26T10:00:00Z',
      'last': {'body': 'and the FAQ', 'created_at': '2026-10-26T11:00:00Z'},
    });
    expect(t.id, 't1');
    expect(t.roomId, 'r1');
    expect(t.title, 'Pricing');
    expect(t.isMain, isFalse);
    expect(t.lastBody, 'and the FAQ');
    expect(t.activeAt, DateTime.utc(2026, 10, 26, 11).toLocal());
  });

  test('the main thread is the room itself', () {
    final main = RoomThread.fromJson({'id': 'r1'}, isMain: true);
    expect(main.isMain, isTrue);
    expect(main.title, 'Main');
    expect(main.lastBody, isEmpty);
    expect(main.activeAt, isNull);
  });
}
