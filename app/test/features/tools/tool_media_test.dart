import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/elpian/core/media.dart';
import 'package:aseman/src/features/tools/runtime/tool_media.dart';
import 'package:aseman/src/genui/genui.dart';

/// A 1x1 transparent PNG.
final _png = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="red"/></svg>';

const _id = '0123456789abcdef0123456789abcdef';

ToolMedia _media(List<String> reads) => ToolMedia(
      baseUrl: 'https://node.example',
      headers: () => {'Authorization': 'Bearer t'},
      fileUrl: (id) => 'https://node.example/v1/files/$id/content',
      proxyUrl: (p) => 'https://node.example$p?token=t',
      readSandbox: (path) async {
        reads.add(path);
        if (path.endsWith('.svg')) return Uint8List.fromList(utf8.encode(_svg));
        if (path.endsWith('missing.png'))
          throw StateError('That file does not exist.');
        return _png;
      },
    );

List<Map<String, dynamic>> _surface(String url) => [
      {
        'version': 'v0.9',
        'createSurface': {
          'surfaceId': 'w',
          'catalogId':
              'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json'
        }
      },
      {
        'version': 'v0.9',
        'updateComponents': {
          'surfaceId': 'w',
          'components': [
            {
              'id': 'root',
              'component': 'Column',
              'children': ['img']
            },
            {'id': 'img', 'component': 'Image', 'url': url},
          ]
        }
      },
    ];

void main() {
  group('ToolMedia', () {
    test('names project files in every spelling', () {
      for (final src in [
        '/workspace/out/a.png',
        'workspace://out/a.png',
        'sandbox:///workspace/out/a.png',
        'file:///workspace/out/a.png',
        'out/a.png',
        './out/a.png',
      ]) {
        expect(ToolMedia.workspacePathOf(src), '/workspace/out/a.png',
            reason: src);
      }
      expect(ToolMedia.workspacePathOf('https://x.example/a.png'), isNull);
      expect(ToolMedia.workspacePathOf('/workspace/../etc/passwd'), isNull);
      expect(ToolMedia.workspacePathOf('/images/a.png'), isNull);
    });

    test('names stored files', () {
      for (final src in [
        _id,
        'attachment://$_id',
        'file://$_id',
        'file:$_id',
        '/v1/files/$_id/content',
        'https://node.example/v1/files/$_id/content',
      ]) {
        expect(ToolMedia.fileIdOf(src), _id, reason: src);
      }
      expect(ToolMedia.fileIdOf('/workspace/a.png'), isNull);
    });

    test('loads each source the right way', () async {
      final reads = <String>[];
      final media = _media(reads);
      final file = (await media('attachment://$_id'))!;
      expect(file.url, 'https://node.example/v1/files/$_id/content');
      expect(file.headers['Authorization'], 'Bearer t');

      final project = (await media('/workspace/out/a.png'))!;
      expect(project.bytes, _png);
      expect(project.mime, 'image/png');
      await media('/workspace/out/a.png');
      expect(reads, ['/workspace/out/a.png'], reason: 'read once, cached');

      final svg = (await media('out/drawing.svg'))!;
      expect(svg.isSvg, isTrue);

      final node = (await media('/icons/x.png'))!;
      expect(node.url, 'https://node.example/icons/x.png');
      expect(node.headers, isNotEmpty);

      expect((await media('/v1/proxy/$_id/frame.png'))!.url,
          'https://node.example/v1/proxy/$_id/frame.png?token=t');

      // Other hosts and inline data are the engine's.
      expect(await media('https://cdn.example/a.png'), isNull);
      expect(await media('data:image/png;base64,AAAA'), isNull);
      expect(await media(_svg), isNull);
    });
  });

  group('ElpianMedia.fallback', () {
    test('reads data URIs, inline SVG and bare base64', () {
      final data =
          ElpianMedia.fallback('data:image/png;base64,${base64.encode(_png)}')!;
      expect(data.bytes, _png);
      expect(data.mime, 'image/png');
      expect(ElpianMedia.fallback(_svg)!.isSvg, isTrue);
      final bare = ElpianMedia.fallback(base64.encode(_png))!;
      expect(bare.mime, 'image/png');
      expect(
          ElpianMedia.fallback('https://a.example/x.jpg')!.isNetwork, isTrue);
    });
  });

  group('generative frontends show media from the space', () {
    Future<void> pump(WidgetTester tester, String url, ToolMedia media) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ElpianMediaScope(
            resolver: media.call,
            child:
                SingleChildScrollView(child: GenUiView(messages: _surface(url))),
          ),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a project image', (tester) async {
      final reads = <String>[];
      await pump(tester, '/workspace/out/a.png', _media(reads));
      expect(reads, ['/workspace/out/a.png']);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<MemoryImage>());
    });

    testWidgets('a project SVG drawing', (tester) async {
      await pump(tester, 'out/drawing.svg', _media([]));
      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('a stored file, with the person\'s credentials',
        (tester) async {
      await pump(tester, 'attachment://$_id', _media([]));
      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image as NetworkImage;
      expect(provider.url, 'https://node.example/v1/files/$_id/content');
      expect(provider.headers?['Authorization'], 'Bearer t');
    });

    testWidgets('a missing file shows a broken image, not an error',
        (tester) async {
      await pump(tester, '/workspace/missing.png', _media([]));
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
