import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/data/models/post.dart';
import 'package:aseman/src/data/models/uploaded_file.dart';
import 'package:aseman/src/features/search_feed/presentation/post_media_grid.dart';

void main() {
  test('a post carries its attachments and source', () {
    final p = SocialPost.fromJson({
      'id': 'p1',
      'author_id': 'a1',
      'body': 'Long BTC',
      'created_at': '2026-10-01T00:00:00Z',
      'source': 'coinmarketcap',
      'attachments': [
        {'id': 'f1', 'name': 'chart.png', 'mime': 'image/png', 'size': 3},
        {'id': 'f2', 'name': 'clip.mp4', 'mime': 'video/mp4', 'size': 9},
      ],
    });
    expect(p.attachments.map((f) => f.id), ['f1', 'f2']);
    expect(p.attachments.last.isVideo, isTrue);
    expect(p.source, 'coinmarketcap');
    final liked = p.withLike(likes: 1, likedByMe: true);
    expect(liked.attachments, p.attachments);
  });

  testWidgets('the grid shows four media and counts the rest', (tester) async {
    final files = [
      for (var i = 0; i < 6; i++)
        UploadedFile(
            id: 'f$i',
            name: 'v$i.mp4',
            mime: i == 0 ? 'video/mp4' : 'video/webm',
            size: 1),
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: PostMediaGrid(
      media: files,
      resolveUrl: (f) => 'https://node/v1/files/${f.id}/content',
      headers: const {},
      download: (_) async => throw UnimplementedError(),
    )))));
    expect(find.byIcon(Icons.play_circle_fill_rounded), findsNWidgets(4));
    expect(find.text('+2'), findsOneWidget);
  });
}
