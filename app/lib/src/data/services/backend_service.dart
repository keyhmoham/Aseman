import '../../domain/models/market_quote.dart';
import '../../domain/models/message.dart';
import '../../domain/models/room.dart';

abstract interface class BackendService {
  Future<List<MarketQuote>> fetchMarketQuotes();
  Future<List<Room>> fetchRooms();
  Future<List<Message>> fetchMessages(String roomId);
}
