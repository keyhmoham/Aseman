import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/search_feed/presentation/post_editor.dart';
import 'package:aseman/src/features/search_feed/presentation/rich_post_content.dart';

void main() {
  testWidgets('rich post content renders formatted markdown and info cards', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RichPostContent(
              '# Title\n\nSome **bold text** and *italic*.\n\n'
              ':::card agent SignalBot\n\n'
              '| A | B |\n|---|---|\n| 1 | 2 |',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Title', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('bold text', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('italic.', findRichText: true), findsOneWidget);
    expect(find.text('AGENT'), findsOneWidget);
    expect(find.text('SignalBot'), findsOneWidget);
    expect(find.text('A', findRichText: true), findsOneWidget);
  });

  Future<Future<String?> Function()> openEditor(
    WidgetTester tester,
    Size size, {
    String? initial,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showPostEditor(ctx, initial: initial);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    return () async => result;
  }

  testWidgets('post editor opens as a desktop modal and returns markdown', (
    tester,
  ) async {
    final result = await openEditor(tester, const Size(1440, 900));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Create a post'), findsOneWidget);
    expect(find.byTooltip('Add chart'), findsOneWidget);
    expect(find.byTooltip('Add info card'), findsOneWidget);
    // A wide screen shows the live preview beside the design.
    expect(find.text('LIVE PREVIEW'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '**hello** world');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();
    expect(await result(), '**hello** world');
  });

  testWidgets('post editor opens as a bottom sheet on mobile', (tester) async {
    await openEditor(tester, const Size(390, 844));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Create a post'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    // A phone switches between designing and previewing.
    expect(find.byTooltip('Preview'), findsOneWidget);
  });

  testWidgets('the designer builds a post from blocks, without markdown', (
    tester,
  ) async {
    final result = await openEditor(tester, const Size(1440, 900));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The empty first paragraph becomes a heading.
    await tester.tap(find.byTooltip('Add heading'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Weekly outlook');
    await tester.pumpAndSettle();

    // A bullet list after it; Enter adds the next item.
    await tester.tap(find.byTooltip('Add bullet list'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'List item').first,
      'BTC holds support',
    );
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'List item').last,
      'ETH lags',
    );
    await tester.pumpAndSettle();

    // Bold through the formatting bar: select the text, then Bold.
    final item = find.widgetWithText(TextField, 'ETH lags');
    final controller = tester.widget<TextField>(item).controller!;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Bold (Ctrl+B)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();
    expect(
      await result(),
      '## Weekly outlook\n\n- BTC holds support\n- **ETH** lags',
    );
  });

  testWidgets('editing a post opens its blocks with their own controls', (
    tester,
  ) async {
    const post =
        '# Title\n\n'
        ':::chart {"type":"line","labels":["A","B"],"values":[1,2]}\n\n'
        '| Coin | Price |\n|---|---|\n| BTC | 100 |';
    final result = await openEditor(
      tester,
      const Size(1440, 900),
      initial: post,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The chart is edited point by point and the table cell by cell.
    expect(find.widgetWithText(TextField, 'Label'), findsNWidgets(2));
    expect(find.widgetWithText(TextField, 'BTC'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '100'), '120');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();
    expect(
      await result(),
      '# Title\n\n'
      ':::chart {"type":"line","labels":["A","B"],"values":[1,2]}\n\n'
      '| Coin | Price |\n|---|---|\n| BTC | 120 |',
    );
  });
}
