import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/shared/widgets/network_content_image.dart';

void main() {
  const fileUrl =
      'https://node.example/v1/files/00000000000000010000000000000001/content';
  const auth = {'Authorization': 'Bearer t'};

  test('public web images never get the session bearer', () {
    expect(mediaRequestHeaders('https://cdn.example/a.png', auth), isEmpty);
    expect(isStoredFileContentUrl('https://cdn.example/a.png'), isFalse);
  });

  test('stored file paths are recognised', () {
    expect(isStoredFileContentUrl(fileUrl), isTrue);
    expect(
        isStoredFileContentUrl(
            '/v1/files/00000000000000010000000000000001/content'),
        isTrue);
  });

  test('native loads of stored files keep the session bearer', () {
    // Tests run as IO, not web: the bearer is required (web uses ?token=).
    expect(mediaRequestHeaders(fileUrl, auth), auth);
  });

  testWidgets('public images render without auth headers', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NetworkContentImage(
            url: 'https://cdn.example/a.png', headers: auth),
      ),
    ));
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<NetworkImage>());
    final provider = image.image as NetworkImage;
    expect(provider.url, 'https://cdn.example/a.png');
    expect(provider.headers, isNull);
    // The test binding rejects the fake host; that is fine — we only care
    // that the bearer was not attached.
    tester.takeException();
  });
}
