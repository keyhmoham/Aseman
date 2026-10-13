import 'package:flutter/foundation.dart';

import '../../../data/repositories/room_repository.dart';
import '../../../domain/models/room.dart';

class ExploreViewModel extends ChangeNotifier {
  ExploreViewModel(this._repository);
  final RoomRepository _repository;
  int selectedCategory = 0;
  List<Room> rooms = const [];

  Future<void> load() async {
    rooms = await _repository.getRooms();
    notifyListeners();
  }

  void selectCategory(int value) {
    selectedCategory = value;
    notifyListeners();
  }
}
