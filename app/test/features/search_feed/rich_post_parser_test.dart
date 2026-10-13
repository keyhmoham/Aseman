import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/features/search_feed/presentation/rich_post_parser.dart';

void main() {
  test('parses headings, bold, links and lists', () {
    final md = '''
# Title

Some **bold** and *italic* with a [link](https://example.com) and `code`.

- one
- two
''';
    final blocks = parseRichMarkdown(md);
    expect(blocks, isNotEmpty);
    expect(blocks[0].kind, BlockKind.heading);
    expect(blocks[0].level, 1);
    expect(
        blocks[0].inline.first.any((t) => t.kind == InlineKind.text), isTrue);

    final para = blocks.firstWhere((b) => b.kind == BlockKind.paragraph);
    final tokens = para.inline.first;
    expect(tokens.any((t) => t.kind == InlineKind.bold), isTrue);
    expect(tokens.any((t) => t.kind == InlineKind.italic), isTrue);
    expect(
        tokens.any((t) =>
            t.kind == InlineKind.link && t.href == 'https://example.com'),
        isTrue);
    expect(tokens.any((t) => t.kind == InlineKind.code), isTrue);

    final bullets = blocks.where((b) => b.kind == BlockKind.bulletList);
    expect(bullets.length, 2);
  });

  test('parses extended directives', () {
    final md = '''
:::chart {"type":"bar","labels":["A"],"values":[3]}
:::video https://cdn/clip.mp4
:::audio https://cdn/note.mp3
:::card agent SignalBot
:::card space Atlas Capital
''';
    final blocks = parseRichMarkdown(md);
    expect(blocks.any((b) => b.kind == BlockKind.chart), isTrue);
    final chart = blocks.firstWhere((b) => b.kind == BlockKind.chart);
    expect(chart.chart?['type'], 'bar');

    expect(blocks.any((b) => b.kind == BlockKind.video), isTrue);
    expect(blocks.firstWhere((b) => b.kind == BlockKind.video).url,
        'https://cdn/clip.mp4');
    expect(blocks.any((b) => b.kind == BlockKind.audio), isTrue);

    final cards = blocks.where((b) => b.kind == BlockKind.card).toList();
    expect(cards.length, 2);
    expect(cards[0].card?.kind, CardKind.agent);
    expect(cards[0].card?.target, 'SignalBot');
    expect(cards[1].card?.kind, CardKind.space);
  });

  test('parses tables and quotes', () {
    final md = '''
| A | B |
|---|---|
| 1 | 2 |
> a quote
''';
    final blocks = parseRichMarkdown(md);
    final table = blocks.firstWhere((b) => b.kind == BlockKind.table);
    expect(table.rows, isNotNull);
    expect(table.rows!.length, 2); // header + one data row (separator skipped)
    expect(blocks.any((b) => b.kind == BlockKind.quote), isTrue);
  });

  test('parses code fence and mentions', () {
    final md = '```dart\nvoid main() {}\n```\nHello @trader!';
    final blocks = parseRichMarkdown(md);
    expect(blocks.any((b) => b.kind == BlockKind.code), isTrue);
    final code = blocks.firstWhere((b) => b.kind == BlockKind.code);
    expect(code.code, contains('void main() {}'));
    final para = blocks.firstWhere((b) => b.kind == BlockKind.paragraph);
    expect(
        para.inline.first
            .any((t) => t.kind == InlineKind.mention && t.text == '@trader'),
        isTrue);
  });
}
