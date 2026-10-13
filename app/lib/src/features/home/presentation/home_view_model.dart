import 'package:flutter/foundation.dart';

import '../../../data/repositories/market_repository.dart';
import '../../../domain/models/market_quote.dart';

class HomeViewModel extends ChangeNotifier {
  HomeViewModel(this._repository);
  final MarketRepository _repository;

  List<MarketQuote> quotes = const [];
  bool loading = false;
  Object? error;

  Future<void> load() async {
    if (loading || quotes.isNotEmpty) return;
    loading = true;
    notifyListeners();
    try {
      quotes = await _repository.getQuotes();
    } catch (value) {
      error = value;
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
