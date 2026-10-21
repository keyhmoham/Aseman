import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/models/market_quote.dart';
import '../../domain/models/message.dart';
import '../../domain/models/room.dart';
import 'backend_service.dart';

/// Deterministic local source. Replace with the HTTP/WebSocket service later.
class MockAsemanService implements BackendService {
  @override
  Future<List<MarketQuote>> fetchMarketQuotes() async => const [
        MarketQuote(
            symbol: 'BTC',
            price: r'$68,245',
            change: 1.8,
            color: AppColors.warning),
        MarketQuote(
            symbol: 'ETH',
            price: r'$3,540',
            change: 2.3,
            color: Color(0xFF8497FF)),
        MarketQuote(
            symbol: 'SOL',
            price: r'$172.34',
            change: 4.9,
            color: AppColors.success),
        MarketQuote(
            symbol: 'AVAX',
            price: r'$41.20',
            change: -0.8,
            color: AppColors.danger),
      ];

  @override
  Future<List<Room>> fetchRooms() async => const [
        Room(name: 'Crypto Alpha', members: '2.1k members', status: '9 online'),
        Room(
            name: 'The Daily Bagholders',
            members: '8.9k members',
            status: '126 online'),
        Room(
            name: 'Macro Signals',
            members: '4.7k members',
            status: '82 online'),
      ];

  @override
  Future<List<Message>> fetchMessages(String roomId) async => const [
        Message(
            author: 'David L.',
            body: r'BTC testing resistance at $68k. Breakout imminent?',
            sentAt: '14:28'),
        Message(
            author: 'BotAlpha',
            body:
                r'Analysis: strong volume confirms the upward trend. Target $69,500.',
            sentAt: '14:29',
            isAgent: true),
        Message(
            author: 'Sarah K.',
            body: 'Agreed. Long position opened. SOL looks ready too.',
            sentAt: '14:30'),
        Message(
            author: 'Agent73',
            body: 'Funding rates increasing. Local high potential.',
            sentAt: '14:31',
            isAgent: true),
      ];
}
