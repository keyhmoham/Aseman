import 'package:aseman/src/features/search_feed/presentation/markup_document.dart';
import 'package:aseman/src/features/search_feed/presentation/rich_post_parser.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a post reads into blocks and writes back unchanged', () {
    const post =
        '# Title\n\n'
        'Some **bold** text\nover two lines\n\n'
        '- one\n- two\n\n'
        '1. first\n2. second\n\n'
        '> a quote\n\n'
        '```python\nprint(1)\n```\n\n'
        '| A | B |\n|---|---|\n| 1 | 2 |\n\n'
        ':::chart {"type":"bar","labels":["Q1","Q2"],"values":[3,4]}\n\n'
        ':::image https://example.com/a.png\n\n'
        ':::card agent AssistBot\n\n'
        '---';
    final blocks = markupToDesign(post);
    expect(blocks.map((b) => b.kind), [
      DesignKind.heading,
      DesignKind.paragraph,
      DesignKind.bullets,
      DesignKind.numbers,
      DesignKind.quote,
      DesignKind.code,
      DesignKind.table,
      DesignKind.chart,
      DesignKind.image,
      DesignKind.card,
      DesignKind.divider,
    ]);
    expect(designToMarkup(blocks), post);
  });

  test('markup the designer has no controls for is kept as it is', () {
    final shared = forwardedPostMarkup(
      id: 'p1',
      authorId: 'a1',
      name: 'Alice',
      body: 'gm',
    );
    final blocks = markupToDesign('hello\n\n$shared');
    expect(blocks.last.kind, DesignKind.raw);
    expect(designToMarkup(blocks), 'hello\n\n$shared');
  });

  test('a lone markdown image becomes an image design block', () {
    final blocks = markupToDesign('![photo](https://example.com/a.png)');
    expect(blocks.single.kind, DesignKind.image);
    expect(blocks.single.url.text, 'https://example.com/a.png');
    expect(designToMarkup(blocks), ':::image https://example.com/a.png');
  });

  test('empty blocks are left out and lists convert to text', () {
    final blocks = [
      DesignBlock(DesignKind.paragraph),
      DesignBlock(DesignKind.bullets, items: ['a', '', 'b']),
      DesignBlock(DesignKind.image),
    ];
    expect(designToMarkup(blocks), '- a\n- b');
    blocks[1].convert(DesignKind.numbers);
    expect(designToMarkup(blocks), '1. a\n2. b');
    blocks[1].convert(DesignKind.paragraph);
    expect(blocks[1].text.text, 'a\n\nb');
  });

  test('formatting wraps the selection and unwraps it again', () {
    final c = MarkupTextController(text: 'ship this now')
      ..selection = const TextSelection(baseOffset: 4, extentOffset: 7);
    c.toggleWrap('**', '**');
    expect(c.text, 'ship **this** now');
    expect(c.selectedText, 'this');
    c.toggleWrap('**', '**');
    expect(c.text, 'ship this now');
  });

  test('formatting snaps a selection to whole words', () {
    expect(MarkupTextController.wordSpan('ship this now', 4, 7), (5, 9));
    expect(MarkupTextController.wordSpan('Docs lag', 0, 3), (0, 4));
    expect(MarkupTextController.wordSpan('a b', 1, 2), (1, 2)); // a space only
    expect(MarkupTextController.wordSpan('naïve café', 1, 9), (0, 10));
    final c = MarkupTextController(text: 'one two')
      ..selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    c.toggleWrap('_', '_');
    expect(c.text, '_one_ two');
  });

  test('a forwarded post renders as a card naming its author', () {
    final md = forwardedPostMarkup(
      id: 'p1',
      authorId: 'a1',
      name: 'Alice',
      handle: 'alice',
      body: '**Ready** notes',
    );
    final block = parseRichMarkdown('Look\n\n$md').last;
    expect(block.kind, BlockKind.forward);
    expect(block.data?['author_id'], 'a1');
    expect(block.data?['body'], '**Ready** notes');
    expect(
      markupPreview('Look\n\n$md'),
      'Look Forwarded post from Alice: Ready notes',
    );
  });
}
