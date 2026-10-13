import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/data/repositories/room_repository.dart';
import 'package:tradera/src/data/services/mock_tradera_service.dart';
import 'package:tradera/src/domain/models/message.dart';

void main() {
  test('keeps messages sent during the current session', () async {
    final repository = RoomRepository(MockTraderaService());
    await repository.getMessages('crypto-alpha');
    repository.send('crypto-alpha',
        const Message(author: 'Alex', body: 'Hello', sentAt: 'now'));

    final messages = await repository.getMessages('crypto-alpha');

    expect(messages.last.body, 'Hello');
  });
}
