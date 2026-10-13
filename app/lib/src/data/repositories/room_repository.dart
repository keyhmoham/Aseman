import '../../domain/models/message.dart';
import '../../domain/models/room.dart';
import '../services/backend_service.dart';

class RoomRepository {
  RoomRepository(this._service);
  final BackendService _service;
  final _messages = <String, List<Message>>{};

  Future<List<Room>> getRooms() => _service.fetchRooms();

  Future<List<Message>> getMessages(String roomId) async {
    if (!_messages.containsKey(roomId)) {
      _messages[roomId] = [...await _service.fetchMessages(roomId)];
    }
    return List.unmodifiable(_messages[roomId]!);
  }

  void send(String roomId, Message message) {
    _messages.putIfAbsent(roomId, () => []).add(message);
  }
}
