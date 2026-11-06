import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/network/api_client.dart';
import 'package:aseman/src/core/network/session_controller.dart';
import 'package:aseman/src/core/network/session_store.dart';
import 'package:aseman/src/core/platform/platform_mode.dart';
import 'package:aseman/src/data/repositories/market_repository.dart';
import 'package:aseman/src/data/repositories/room_repository.dart';
import 'package:aseman/src/data/services/aseman_service.dart';
import 'package:aseman/src/features/platform/platform_home.dart';
import 'package:aseman/src/features/tools/elpian_app/elpian_app_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../fake_aseman_service.dart';

/// Records what each auth call sent and answers like the node.
class _AuthClient extends AsemanApiClient {
  _AuthClient() : super(baseUrl: 'http://localhost:8080');

  final sent = <String, Map<String, dynamic>>{};

  @override
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
  }) async {
    sent['$namespace.$action'] = body;
    if (namespace == 'developer' && action == 'platform_frontend') {
      return const ApiResponse(200, {
        'platform': {'id': 'pf1', 'slug': 'acme', 'name': 'Acme'},
        'frontend': {
          'title': 'Store',
          'ui': 'elpian',
          'entry': '',
          'url': '/v1/platforms/acme/app/',
        },
      });
    }
    return const ApiResponse(200, {
      'account_id': 'u7',
      'handle': 'shopper',
      'token': 't',
      'private_key': '',
      'public_key': '',
      'platform_id': 'pf1',
    });
  }
}

/// A service whose platform has [info] (or cannot be reached: null).
class _PlatformService extends FakeAsemanService {
  _PlatformService(this.info);

  PlatformInfo? info;
  int asked = 0;

  /// What waking the platform's computer answers, in turn (the last repeats).
  List<Map<String, dynamic>> wakes = [
    {'state': 'ready', 'ready': true},
  ];
  int woken = 0;

  @override
  Future<Map<String, dynamic>> platformWake(String slug,
      {Duration wait = const Duration(seconds: 15)}) async {
    final w = wakes[woken < wakes.length ? woken : wakes.length - 1];
    woken++;
    return w;
  }

  @override
  Future<PlatformInfo> platformInfo([String? slug]) async {
    asked++;
    final i = info;
    if (i == null) throw StateError('node unreachable');
    return i;
  }
}

void main() {
  tearDown(() => PlatformMode.debugSlug = null);

  test('main Aseman unless a valid platform slug is configured', () {
    expect(PlatformMode.active, isFalse);
    expect(PlatformMode.authField, isEmpty);
    PlatformMode.debugSlug = 'Acme';
    expect(PlatformMode.slug, 'acme');
    expect(PlatformMode.authField, {'platform': 'acme'});
    PlatformMode.debugSlug = '../evil';
    expect(PlatformMode.active, isFalse);
  });

  test('a platform client signs in to the platform and keeps it', () async {
    final client = _AuthClient();
    final service = AsemanService(client);

    await service.login(account: 'shopper', password: 'pw');
    expect(client.sent['auth.login']!.containsKey('platform'), isFalse);

    PlatformMode.debugSlug = 'acme';
    final s = await service.login(account: 'shopper', password: 'pw');
    expect(client.sent['auth.login']!['platform'], 'acme');
    await service.register(handle: 'new', email: 'n@x.test', password: 'pw');
    expect(client.sent['auth.register']!['platform'], 'acme');
    await service.oauth('google', 'id');
    expect(client.sent['auth.oauth_google']!['platform'], 'acme');

    expect(s.platformId, 'pf1');
    expect(Session.fromJson(s.toJson()).platformId, 'pf1');

    final info = await service.platformInfo();
    expect(client.sent['developer.platform_frontend'], {'platform': 'acme'});
    expect(info.name, 'Acme');
    expect(info.frontend!.isWeb, isFalse);
    expect(info.frontend!.entry, 'elpian/app.js');
  });

  test('the frontend address is a gateway path, signed in', () {
    final service = AsemanService(AsemanApiClient(baseUrl: 'https://node.test'))
      ..client.session = const Session(
          accountId: 'u7', handle: 'shopper', token: 'tok', privateKey: '', publicKey: '');
    expect(service.proxyUrl('/v1/platforms/acme/app/'),
        'https://node.test/v1/platforms/acme/app/?token=tok');
    expect(() => service.proxyUrl('/v1/platforms/acme/other/'), throwsFormatException);
    expect(() => service.proxyUrl('/v1/platforms/acme/app/../x'), throwsFormatException);
  });

  group('platform home', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<_PlatformService> pump(WidgetTester tester, PlatformInfo? info,
        {List<Map<String, dynamic>>? wakes}) async {
      final service = _PlatformService(info);
      if (wakes != null) service.wakes = wakes;
      final deps = AppDependencies(
        sessionController: SessionController(service),
        service: service,
        marketRepository: MarketRepository(service),
        roomRepository: RoomRepository(service),
      );
      await tester.pumpWidget(MaterialApp(home: PlatformHome(dependencies: deps)));
      await tester.pump();
      return service;
    }

    testWidgets('an unreachable platform offers to try again', (tester) async {
      final service = await pump(tester, null);
      expect(find.text('This platform could not be reached'), findsOneWidget);
      service.info = const PlatformInfo(id: 'pf1', slug: 'acme', name: 'Acme');
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(service.asked, 2);
    });

    testWidgets('a published Elpian frontend is home, with the menu',
        (tester) async {
      await pump(
          tester,
          const PlatformInfo(
            id: 'pf1',
            slug: 'acme',
            name: 'Acme',
            frontend: PlatformFrontendInfo(
                title: 'Store',
                ui: 'elpian',
                entry: 'elpian/app.js',
                url: '/v1/platforms/acme/app/'),
          ));
      await tester.pump();
      final view = tester.widget<ElpianAppView>(find.byType(ElpianAppView));
      expect(view.page, '/v1/platforms/acme/app/');
      expect(view.onAsleep, isNotNull);
      expect(view.entry, 'elpian/app.js');
      await tester.tap(find.byKey(const ValueKey('platform-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    const store = PlatformInfo(
      id: 'pf1',
      slug: 'acme',
      name: 'Acme',
      frontend: PlatformFrontendInfo(
          title: 'Store',
          ui: 'elpian',
          entry: 'elpian/app.js',
          url: '/v1/platforms/acme/app/'),
    );

    testWidgets('opening the platform wakes its computer first',
        (tester) async {
      final service = await pump(tester, store, wakes: [
        {'state': 'waking', 'retry_after_ms': 500},
        {'state': 'ready', 'ready': true},
      ]);
      expect(find.text('Waking up… this takes a moment the first time.'),
          findsOneWidget);
      expect(find.byType(ElpianAppView), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(service.woken, 2);
      expect(find.byType(ElpianAppView), findsOneWidget);
    });

    testWidgets('a computer that could not wake says why and retries',
        (tester) async {
      final service = await pump(tester, store, wakes: [
        {'state': 'failed', 'error': 'the publisher is out of funds'},
      ]);
      await tester.pump();
      expect(find.text('Could not wake up: the publisher is out of funds'),
          findsOneWidget);
      service.wakes = [
        {'state': 'ready', 'ready': true},
      ];
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(ElpianAppView), findsOneWidget);
    });
  });
}
