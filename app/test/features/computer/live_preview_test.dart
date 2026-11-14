import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/computer/preview_view.dart';
import 'package:aseman/src/features/desk/presentation/web_page_view.dart';

import '../../fake_aseman_service.dart';

const _page = '/v1/proxy/0123456789abcdef0123456789abcdef/';

/// A node whose computer sleeps until a preview is opened.
class _Service extends FakeAsemanService {
  String state = 'asleep';
  Completer<Map<String, dynamic>>? opening;
  final opened = <String>[];

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
    bool anonymous = false,
  }) async {
    final call = '$namespace.$action';
    if (call == 'spaces.computer') {
      return {'state': state, 'rev': state};
    }
    if (call == 'spaces.proxy_open') {
      opened.add('${body['proxy']}');
      opening = Completer();
      final r = await opening!.future;
      state = 'awake';
      return r;
    }
    return super.invokeAction(namespace, action, body: body, timeout: timeout, anonymous: anonymous);
  }
}

void main() {
  Future<void> pump(WidgetTester tester, _Service service) async {
    // A platform without a native web view: the page is a notice here.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LivePreview(
            service: service,
            spaceId: FakeAsemanService.atlasId,
            page: _page,
            title: 'Shop',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a sleeping computer is woken, then the page is shown', (
    tester,
  ) async {
    final service = _Service();
    await pump(tester, service);
    expect(service.opened, ['0123456789abcdef0123456789abcdef']);
    expect(find.text('Waking the computer…'), findsOneWidget);
    expect(find.byType(WebPageView), findsNothing);

    service.opening!.complete({'ready': true});
    await tester.pump();
    await tester.pump();
    expect(find.byType(WebPageView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an app that did not start says why and can be retried', (
    tester,
  ) async {
    final service = _Service()..state = 'awake';
    await pump(tester, service);
    expect(find.text('Starting Shop…'), findsOneWidget);
    service.opening!.complete({
      'ready': false,
      'can_start': true,
      'log': 'Error: port in use',
    });
    await tester.pump();
    expect(find.text('Not available right now'), findsOneWidget);
    expect(find.text('Shop did not start on the computer.'), findsOneWidget);
    expect(find.text('Error: port in use'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(service.opened, hasLength(2));
    service.opening!.complete({'ready': true});
    await tester.pump();
    await tester.pump();
    expect(find.byType(WebPageView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  test('preview records name their kind', () {
    PublishedPreview p(Map<String, dynamic> m) => PublishedPreview.fromJson(m);
    expect(p({'port': 3000}).title, 'Port 3000');
    expect(p({'port': 3000}).kind, 'preview');
    expect(p({'port': 6080, 'title': 'Desktop'}).kind, 'desktop');
    expect(p({'port': 1, 'title': 'Tool · X'}).kind, 'tool');
    expect(
      p({'port': 1, 'kind': 'preview', 'title': 'Desktop'}).kind,
      'preview',
    );
    expect(proxyIdOf(_page), '0123456789abcdef0123456789abcdef');
    expect(proxyIdOf('https://example.com/'), isNull);
  });
}
