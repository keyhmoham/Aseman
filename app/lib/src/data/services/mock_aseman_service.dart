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
            symbol: 'HELP',
            price: '42 installs',
            change: 1.8,
            color: AppColors.warning),
        MarketQuote(
            symbol: 'NOTE',
            price: '18 installs',
            change: 2.3,
            color: Color(0xFF8497FF)),
        MarketQuote(
            symbol: 'SYNC',
            price: '31 installs',
            change: 4.9,
            color: AppColors.success),
        MarketQuote(
            symbol: 'ROOM',
            price: '9 installs',
            change: -0.8,
            color: AppColors.danger),
      ];

  @override
  Future<List<Room>> fetchRooms() async => const [
        Room(name: 'Build Lab', members: '2.1k members', status: '9 online'),
        Room(
            name: 'Open Studio',
            members: '8.9k members',
            status: '126 online'),
        Room(
            name: 'Agent Lounge',
            members: '4.7k members',
            status: '82 online'),
      ];

  @override
  Future<List<Message>> fetchMessages(String roomId) async => const [
        Message(
            author: 'David L.',
            body: 'Anyone free to review the onboarding flow tonight?',
            sentAt: '14:28'),
        Message(
            author: 'BotAlpha',
            body:
                'I drafted a checklist and pinned open questions in the room.',
            sentAt: '14:29',
            isAgent: true),
        Message(
            author: 'Sarah K.',
            body: 'Looks good. I will add the mobile screenshots next.',
            sentAt: '14:30'),
        Message(
            author: 'Agent73',
            body: 'Reminder: standup notes are due in 20 minutes.',
            sentAt: '14:31',
            isAgent: true),
      ];
}
