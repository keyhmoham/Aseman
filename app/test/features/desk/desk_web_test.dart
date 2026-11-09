import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/features/desk/data/desk_api.dart';
import 'package:aseman/src/features/desk/domain/desk_models.dart';
import 'package:aseman/src/features/desk/presentation/desk_controller.dart';
import 'package:aseman/src/features/desk/presentation/web_page_view.dart';

import '../../fake_aseman_service.dart';

const _page = '/v1/proxy/0000000000000001626f3df602aaad3d/orders';

void main() {
  test('a web page window reads its page and shows no args', () {
    final w = DeskWindow.fromJson({
      'id': 'w1',
      'tool': 'bot-wx',
      'kind': 'web',
      'frontend': 'web',
      'args': {'page': _page},
      'x': 0,
      'y': 0,
      'w': 720,
      'h': 600,
    });
    expect(w.isWeb, isTrue);
    expect(w.page, _page);
    expect(w.argsSummary, isEmpty);
    expect(w.shown, isNotNull, reason: 'pins match it by its args');
    final p = DeskPin.fromJson({'id': 'p1', 'tool': 'pages', 'kind': 'web', 'args': {'page': _page}});
    expect(p.isWeb, isTrue);
    expect(p.page, _page);
  });

  test('openPage opens a web window on the desk', () async {
    final sent = <Map<String, dynamic>>[];
    final controller = DeskController(DeskApi((ns, action, body, {timeout}) async {
      if (action == 'desktop_get') return {'desktop': {'version': 1, 'windows': <dynamic>[], 'pins': <dynamic>[]}};
      sent.addAll((body['ops'] as List).cast<Map<String, dynamic>>());
      return {'desktop': {'version': 2, 'windows': <dynamic>[], 'pins': <dynamic>[]}, 'ids': ['w9']};
    }), pollEvery: const Duration(hours: 1));
    controller.attach('space1', 'room1');
    final id = await controller.openPage(_page, tool: 'bot-wx', title: 'Weather console');
    expect(id, 'w9');
    expect(sent.single, {
      'op': 'open',
      'tool': 'bot-wx',
      'kind': 'web',
      'title': 'Weather console',
      'args': {'page': _page},
      'w': 720.0,
      'h': 600.0,
    });
    controller.dispose();
  });

  test('the page loads signed in, in the app theme', () async {
    final service = FakeAsemanService();
    const accent = Color(0xFF8B7BFF);
    final theme = webPageTheme(AppTheme.darkWith(accent), accent: accent);
    expect(theme['mode'], 'dark');
    expect(theme['accent'], '#8b7bff');
    expect((theme['scheme'] as Map)['primary'], '#c7bfff');
    final url = Uri.parse(webPageUrl(service, _page, theme));
    expect(url.path, _page);
    expect(url.queryParameters['decillion_theme'], 'dark');
    expect(url.queryParameters['decillion_embed'], 'desk');
    expect(url.queryParameters['decillion_accent'], '#8b7bff');
    final scheme = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(url.queryParameters['decillion_scheme']!))));
    expect(scheme['surface'], '#111119');
    expect(() => webPageUrl(service, 'https://evil.example/', theme), throwsFormatException);
  });

  testWidgets('where pages cannot show in the app, they open in the browser', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: WebPageView(service: FakeAsemanService(), page: _page))));
    expect(find.text('/orders'), findsOneWidget);
    expect(find.text('Opens in your browser'), findsOneWidget);
    expect(find.text('Open page'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
