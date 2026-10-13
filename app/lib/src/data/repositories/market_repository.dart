import '../../domain/models/market_quote.dart';
import '../services/backend_service.dart';

class MarketRepository {
  MarketRepository(this._service);
  final BackendService _service;
  List<MarketQuote>? _cache;

  Future<List<MarketQuote>> getQuotes({bool refresh = false}) async {
    if (!refresh && _cache != null) return _cache!;
    return _cache = List.unmodifiable(await _service.fetchMarketQuotes());
  }
}
