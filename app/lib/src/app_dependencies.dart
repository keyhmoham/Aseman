import 'package:flutter/foundation.dart' show kIsWeb;

import 'core/network/api_client.dart';
import 'core/network/session_controller.dart';
import 'data/repositories/market_repository.dart';
import 'data/repositories/room_repository.dart';
import 'data/services/tradera_service.dart';
import 'shared/widgets/avatar.dart';

/// Base URL of the Tradera gateway. Override at build time with
/// `--dart-define=API_BASE_URL=...` (web/mobile) or edit here. The special
/// value `same-origin` makes a web build call the server it is served from
/// (the docker compose setup serves the app and proxies the API on one origin).
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8080',
);

/// The effective API base URL (resolves `same-origin` on the web).
String resolveApiBaseUrl() {
  if (kApiBaseUrl == 'same-origin' || kApiBaseUrl.isEmpty) {
    return kIsWeb ? Uri.base.origin : 'http://10.0.2.2:8080';
  }
  return kApiBaseUrl;
}

/// App-level composition root. Provides the signed API client, the server
/// service and the repositories consumed by the UI.
class AppDependencies {
  AppDependencies({
    required this.sessionController,
    required this.service,
    required this.marketRepository,
    required this.roomRepository,
  }) {
    // Avatars anywhere in the app show their pictures through this service.
    Avatars.resolve = service.avatarImage;
  }

  factory AppDependencies.create({String? baseUrl}) {
    final client = TraderaApiClient(baseUrl: baseUrl ?? resolveApiBaseUrl());
    final service = TraderaService(client);
    final sessionController = SessionController(service);
    return AppDependencies(
      sessionController: sessionController,
      service: service,
      marketRepository: MarketRepository(service),
      roomRepository: RoomRepository(service),
    );
  }

  /// Wiring with a pre-built service (used by tests with a fake service).
  factory AppDependencies.withService(TraderaService service) {
    final sessionController = SessionController(service);
    return AppDependencies(
      sessionController: sessionController,
      service: service,
      marketRepository: MarketRepository(service),
      roomRepository: RoomRepository(service),
    );
  }

  final SessionController sessionController;
  final TraderaService service;
  final MarketRepository marketRepository;
  final RoomRepository roomRepository;
}
