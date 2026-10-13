import 'package:flutter/foundation.dart';

import '../../../data/repositories/room_repository.dart';
import '../../../domain/models/message.dart';

class RoomViewModel extends ChangeNotifier {
  RoomViewModel(this._repository, {this.author = 'me'});
  final RoomRepository _repository;
  final String author;
  static const roomId = 'crypto-alpha';

  List<Message> messages = const [];
  bool loading = false;

  Future<void> load() async {
    loading = true;
    notifyListeners();
    messages = await _repository.getMessages(roomId);
    loading = false;
    notifyListeners();
  }

  void send(String body) {
    final text = body.trim();
    if (text.isEmpty) return;
    final message = Message(author: author, body: text, sentAt: 'now');
    _repository.send(roomId, message);
    messages = [...messages, message];
    notifyListeners();
  }
}
