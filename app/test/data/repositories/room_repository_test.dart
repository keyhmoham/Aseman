import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/data/repositories/room_repository.dart';
import 'package:aseman/src/data/services/mock_aseman_service.dart';
import 'package:aseman/src/domain/models/message.dart';

void main() {
  test('keeps messages sent during the current session', () async {
    final repository = RoomRepository(MockAsemanService());
    await repository.getMessages('crypto-alpha');
    repository.send('crypto-alpha',
        const Message(author: 'Alex', body: 'Hello', sentAt: 'now'));

    final messages = await repository.getMessages('crypto-alpha');

    expect(messages.last.body, 'Hello');
  });
}
