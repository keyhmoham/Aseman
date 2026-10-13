import 'package:flutter/material.dart';

class MarketQuote {
  const MarketQuote(
      {required this.symbol,
      required this.price,
      required this.change,
      required this.color});
  final String symbol;
  final String price;
  final double change;
  final Color color;
}
