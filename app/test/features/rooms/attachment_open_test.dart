import 'dart:convert';
import 'dart:typed_data';

import 'package:aseman/src/data/models/uploaded_file.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/attachment_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'a document in a chat opens in the workspace viewer, in a bottom sheet '
      'without a desk', (tester) async {
    var reads = 0;
    const file = UploadedFile(
        id: '0123456789abcdef0123456789abcdef',
        name: 'notes.md',
        mime: 'text/markdown',
        size: 24);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: AttachmentBubble(
                    file: file,
                    headers: const {},
                    resolveUrl: (_) => 'https://node.example/v1/files/x/content',
                    fetchBytes: (_) async {
                      reads++;
                      return Uint8List.fromList(
                          utf8.encode('# Release notes\n\nAll good.'));
                    })))));
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Release notes', findRichText: true), findsOneWidget);
    expect(find.byTooltip('Download'), findsWidgets);
  });
}
