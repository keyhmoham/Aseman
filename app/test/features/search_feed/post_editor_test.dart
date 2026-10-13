import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/features/search_feed/presentation/post_editor.dart';
import 'package:tradera/src/features/search_feed/presentation/rich_post_content.dart';

void main() {
  testWidgets('rich post content renders formatted markdown and info cards',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: RichPostContent(
      '# Title\n\nSome **bold text** and *italic*.\n\n'
      ':::card agent SignalBot\n\n'
      '| A | B |\n|---|---|\n| 1 | 2 |',
    )))));
    expect(find.text('Title', findRichText: true), findsOneWidget);
    expect(
        find.textContaining('bold text', findRichText: true), findsOneWidget);
    expect(find.textContaining('italic.', findRichText: true), findsOneWidget);
    expect(find.text('AGENT'), findsOneWidget);
    expect(find.text('SignalBot'), findsOneWidget);
    expect(find.text('A', findRichText: true), findsOneWidget);
  });

  testWidgets('post editor opens as a desktop modal and returns markdown',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    String? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => Center(
                      child: ElevatedButton(
                        onPressed: () async {
                          result = await showPostEditor(ctx);
                        },
                        child: const Text('open'),
                      ),
                    )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Publish a post'), findsOneWidget);
    expect(find.byTooltip('Chart'), findsOneWidget);
    expect(find.byTooltip('Info card'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '**hello** world');
    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();
    expect(result, '**hello** world');
  });

  testWidgets('post editor opens as a bottom sheet on mobile', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => Center(
                      child: ElevatedButton(
                        onPressed: () => showPostEditor(ctx),
                        child: const Text('open'),
                      ),
                    )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Publish a post'), findsOneWidget);
    // Bottom sheet is used on mobile; verify the toolbar preview toggle exists.
    expect(find.text('Preview'), findsOneWidget);
  });
}
