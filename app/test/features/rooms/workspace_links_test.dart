import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/network/api_client.dart';
import 'package:aseman/src/core/network/session_store.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/data/models/uploaded_file.dart';
import 'package:aseman/src/data/services/aseman_service.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/workspace_links.dart';
import 'package:aseman/src/features/search_feed/presentation/rich_post_content.dart';

const fileId = '00000000000000010000000000000001';

class _Files extends AsemanService {
  _Files() : super(AsemanApiClient(baseUrl: 'https://node.example'));
  String? requested;
  @override
  Future<UploadedFile> fetchFile(String id, {bool withData = false}) async {
    requested = id;
    return const UploadedFile(
        id: fileId,
        name: 'corrected-site.zip',
        mime: 'application/zip',
        size: 39748);
  }
}

void main() {
  testWidgets('actual attachment report link opens the authorized file card',
      (tester) async {
    final service = _Files();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => RichPostContent(
                    '[Download ZIP](attachment://$fileId)',
                    onLinkTap: (link) =>
                        openWorkspaceLink(context, service, link))))));
    await tester.tap(find.text('Download ZIP ↗'));
    await tester.pumpAndSettle();
    expect(service.requested, fileId);
    expect(find.text('Delivered file'), findsOneWidget);
    expect(find.text('corrected-site.zip'), findsOneWidget);
    expect(find.textContaining('tap to open'), findsOneWidget);
  });

  test(
      'gateway URL preserves queries, adds current auth once and rejects foreign paths',
      () {
    final service = _Files();
    service.client.session = const Session(
        accountId: 'me',
        handle: 'me',
        token: 'private token/+?',
        privateKey: '',
        publicKey: '');
    final url = Uri.parse(
        service.proxyUrl('/v1/proxy/$fileId/?view=demo&token=old#contact'));
    expect(url.origin, 'https://node.example');
    expect(url.queryParameters, {'view': 'demo', 'token': 'private token/+?'});
    expect(url.fragment, 'contact');
    for (final path in [
      'https://evil.example/v1/proxy/$fileId/',
      '//evil.example/',
      '/v1/proxy/$fileId/../admin/',
      '/v1/proxy/$fileId/%2e%2e/admin/',
      '/v1/other/action'
    ]) {
      expect(() => service.proxyUrl(path), throwsFormatException);
    }
  });

  test(
      'room polling detects a same-size page rotation and attachment enrichment',
      () {
    RoomMessage message(String id, {List<UploadedFile> files = const []}) =>
        RoomMessage(
            id: id,
            spaceId: 'space',
            roomId: 'room',
            senderId: 'worker',
            body: 'Delivered',
            createdAt: DateTime.utc(2026),
            attachments: files);
    expect(message('old').hasSameContentAs(message('new')), false);
    expect(message('same').hasSameContentAs(message('same')), true);
    expect(
        message('same').hasSameContentAs(message('same', files: const [
          UploadedFile(
              id: fileId, name: 'index.html', mime: 'text/html', size: 100)
        ])),
        false);
  });
}
