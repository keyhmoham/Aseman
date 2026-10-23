/// The visual designer's model of a post or message: a list of blocks
/// (paragraphs, headings, lists, tables, charts, media, cards…), each edited
/// with its own controls, read from and written back to the platform's
/// markdown dialect (see rich_post_parser.dart).
library;

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/material.dart';

/// The kinds of blocks the designer edits.
enum DesignKind {
  paragraph,
  heading,
  bullets,
  numbers,
  quote,
  code,
  table,
  chart,
  image,
  video,
  audio,
  card,
  divider,

  /// Markup the designer has no controls for (a forwarded post, an unknown
  /// directive): kept as it is and editable as text.
  raw,
}

/// How each kind is named and drawn in the designer's palette.
extension DesignKindInfo on DesignKind {
  String get label => switch (this) {
    DesignKind.paragraph => 'Text',
    DesignKind.heading => 'Heading',
    DesignKind.bullets => 'Bullet list',
    DesignKind.numbers => 'Numbered list',
    DesignKind.quote => 'Quote',
    DesignKind.code => 'Code',
    DesignKind.table => 'Table',
    DesignKind.chart => 'Chart',
    DesignKind.image => 'Image',
    DesignKind.video => 'Video',
    DesignKind.audio => 'Audio',
    DesignKind.card => 'Info card',
    DesignKind.divider => 'Divider',
    DesignKind.raw => 'Custom markup',
  };

  IconData get icon => switch (this) {
    DesignKind.paragraph => Icons.notes_rounded,
    DesignKind.heading => Icons.title_rounded,
    DesignKind.bullets => Icons.format_list_bulleted_rounded,
    DesignKind.numbers => Icons.format_list_numbered_rounded,
    DesignKind.quote => Icons.format_quote_rounded,
    DesignKind.code => Icons.code_rounded,
    DesignKind.table => Icons.table_chart_outlined,
    DesignKind.chart => Icons.bar_chart_rounded,
    DesignKind.image => Icons.image_outlined,
    DesignKind.video => Icons.videocam_outlined,
    DesignKind.audio => Icons.graphic_eq_rounded,
    DesignKind.card => Icons.badge_outlined,
    DesignKind.divider => Icons.horizontal_rule_rounded,
    DesignKind.raw => Icons.data_object_rounded,
  };

  /// Whether the block is edited as formatted text (bold, links, …).
  bool get isText =>
      this == DesignKind.paragraph ||
      this == DesignKind.heading ||
      this == DesignKind.quote;

  bool get isList => this == DesignKind.bullets || this == DesignKind.numbers;

  bool get isMedia =>
      this == DesignKind.image ||
      this == DesignKind.video ||
      this == DesignKind.audio;
}

/// The kinds of `:::card` the designer offers, with their labels.
const designCardKinds = [
  ('user', 'Trader', Icons.person_rounded),
  ('agent', 'Agent', Icons.smart_toy_rounded),
  ('tool', 'App', Icons.apps_rounded),
  ('space', 'Workspace', Icons.hub_rounded),
];

/// The code languages offered for a code block.
const designCodeLanguages = [
  '',
  'python',
  'javascript',
  'typescript',
  'dart',
  'go',
  'rust',
  'java',
  'sql',
  'json',
  'yaml',
  'bash',
  'html',
  'css',
];

int _nextKey = 0;

/// One block of the designer, with the controllers its editor uses.
class DesignBlock {
  DesignBlock(
    this.kind, {
    String text = '',
    this.level = 2,
    this.language = '',
    List<String>? items,
    List<List<String>>? cells,
    this.chartType = 'bar',
    List<(String, String)>? points,
    String url = '',
    this.cardKind = 'user',
    String target = '',
  }) : key = ValueKey('design-block-${_nextKey++}'),
       text = MarkupTextController(text: text),
       url = TextEditingController(text: url),
       target = TextEditingController(text: target) {
    for (final item in items ?? (kind.isList ? const [''] : const <String>[])) {
      this.items.add(MarkupTextController(text: item));
    }
    for (final row
        in cells ??
            (kind == DesignKind.table
                ? const [
                    ['Column 1', 'Column 2'],
                    ['', ''],
                  ]
                : const <List<String>>[])) {
      this.cells.add([for (final c in row) TextEditingController(text: c)]);
    }
    for (final (label, value)
        in points ??
            (kind == DesignKind.chart
                ? const [('Q1', '12'), ('Q2', '18'), ('Q3', '15'), ('Q4', '24')]
                : const <(String, String)>[])) {
      this.points.add((
        TextEditingController(text: label),
        TextEditingController(text: value),
      ));
    }
  }

  /// A new, empty block of [kind] with sensible starting content.
  factory DesignBlock.empty(DesignKind kind) => switch (kind) {
    DesignKind.code => DesignBlock(kind, language: 'python'),
    _ => DesignBlock(kind),
  };

  DesignKind kind;
  final Key key;

  /// Text of a paragraph, heading, quote, code or custom-markup block.
  final MarkupTextController text;

  /// A heading's level (1–6; the designer offers 1–3).
  int level;

  /// A code block's language ("" for none).
  String language;

  /// A list's items.
  final List<MarkupTextController> items = [];

  /// A table's cells, the first row its header.
  final List<List<TextEditingController>> cells = [];

  /// A chart's type ("bar" or "line") and its points (label, value).
  String chartType;
  final List<(TextEditingController, TextEditingController)> points = [];

  /// A media block's address.
  final TextEditingController url;

  /// An info card's kind (user, agent, tool, space) and who it is about.
  String cardKind;
  final TextEditingController target;

  /// A copy of this block with fresh controllers.
  DesignBlock duplicate() => DesignBlock(
    kind,
    text: text.text,
    level: level,
    language: language,
    items: [for (final i in items) i.text],
    cells: [
      for (final row in cells) [for (final c in row) c.text],
    ],
    chartType: chartType,
    points: [for (final (l, v) in points) (l.text, v.text)],
    url: url.text,
    cardKind: cardKind,
    target: target.text,
  );

  /// Turns a list into the other kind of list, or text into another text
  /// kind, keeping what was written.
  void convert(DesignKind to) {
    if (kind.isList && to.isList || kind.isText && to.isText) {
      kind = to;
      return;
    }
    if (kind.isText && to.isList) {
      final lines = text.text.split('\n').where((l) => l.trim().isNotEmpty);
      for (final i in items) {
        i.dispose();
      }
      items
        ..clear()
        ..addAll([
          for (final l in lines.isEmpty ? [''] : lines)
            MarkupTextController(text: l),
        ]);
      kind = to;
      return;
    }
    if (kind.isList && to.isText) {
      text.text = items.map((i) => i.text).join('\n');
      kind = to;
    }
  }

  /// Whether the block has nothing in it worth publishing.
  bool get isEmpty => switch (kind) {
    DesignKind.divider => false,
    DesignKind.table => cells.every(
      (row) => row.every((c) => c.text.trim().isEmpty),
    ),
    DesignKind.chart => _chartValues().isEmpty,
    DesignKind.card => target.text.trim().isEmpty,
    _ when kind.isList => items.every((i) => i.text.trim().isEmpty),
    _ when kind.isMedia => url.text.trim().isEmpty,
    _ => text.text.trim().isEmpty,
  };

  List<num> _chartValues() => [
    for (final (_, v) in points)
      if (num.tryParse(v.text.trim()) != null) num.parse(v.text.trim()),
  ];

  /// The block as markup.
  String toMarkup() {
    switch (kind) {
      case DesignKind.paragraph:
        return text.text.trimRight();
      case DesignKind.heading:
        return '${'#' * level.clamp(1, 6)} ${_oneLine(text.text)}';
      case DesignKind.quote:
        return text.text
            .trimRight()
            .split('\n')
            .map((l) => l.trim().isEmpty ? '>' : '> $l')
            .join('\n');
      case DesignKind.bullets:
        return [
          for (final i in items)
            if (i.text.trim().isNotEmpty) '- ${_oneLine(i.text)}',
        ].join('\n');
      case DesignKind.numbers:
        final kept = items.where((i) => i.text.trim().isNotEmpty).toList();
        return [
          for (var n = 0; n < kept.length; n++)
            '${n + 1}. ${_oneLine(kept[n].text)}',
        ].join('\n');
      case DesignKind.code:
        return '```$language\n${text.text.trimRight()}\n```';
      case DesignKind.table:
        String row(List<TextEditingController> r) =>
            '| ${r.map((c) => _cell(c.text)).join(' | ')} |';
        if (cells.isEmpty) return '';
        return [
          row(cells.first),
          '|${List.filled(cells.first.length, '---').join('|')}|',
          for (final r in cells.skip(1))
            if (r.any((c) => c.text.trim().isNotEmpty)) row(r),
        ].join('\n');
      case DesignKind.chart:
        final labels = <String>[];
        final values = <num>[];
        for (final (l, v) in points) {
          final n = num.tryParse(v.text.trim());
          if (n == null) continue;
          labels.add(l.text.trim());
          values.add(n);
        }
        return ':::chart ${jsonEncode({'type': chartType, 'labels': labels, 'values': values})}';
      case DesignKind.image:
      case DesignKind.video:
      case DesignKind.audio:
        return ':::${kind.name} ${url.text.trim()}';
      case DesignKind.card:
        return ':::card $cardKind ${_oneLine(target.text)}';
      case DesignKind.divider:
        return '---';
      case DesignKind.raw:
        return text.text.trim();
    }
  }

  void dispose() {
    text.dispose();
    url.dispose();
    target.dispose();
    for (final i in items) {
      i.dispose();
    }
    for (final row in cells) {
      for (final c in row) {
        c.dispose();
      }
    }
    for (final (l, v) in points) {
      l.dispose();
      v.dispose();
    }
  }

  static String _oneLine(String s) =>
      s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

  static String _cell(String s) => _oneLine(s).replaceAll('|', '/');
}

/// Writes [blocks] as one markup document, leaving out empty ones.
String designToMarkup(List<DesignBlock> blocks) => blocks
    .where((b) => !b.isEmpty)
    .map((b) => b.toMarkup())
    .where((m) => m.trim().isNotEmpty)
    .join('\n\n');

/// Reads a markup document into designer blocks. Everything it does not
/// recognize becomes a custom-markup block, so nothing is lost.
List<DesignBlock> markupToDesign(String source) {
  final blocks = <DesignBlock>[];
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final para = <String>[];
  void flush() {
    if (para.isEmpty) return;
    blocks.add(DesignBlock(DesignKind.paragraph, text: para.join('\n')));
    para.clear();
  }

  final bullet = RegExp(r'^\s*[-*+]\s+(.*)$');
  final number = RegExp(r'^\s*\d+[.)]\s+(.*)$');
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final t = line.trim();
    if (t.isEmpty) {
      flush();
      i++;
      continue;
    }
    if (t.startsWith('```')) {
      flush();
      final language = t.substring(3).trim().split(RegExp(r'\s')).first;
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      i++; // the closing fence
      blocks.add(
        DesignBlock(DesignKind.code, text: code.join('\n'), language: language),
      );
      continue;
    }
    if (t.startsWith('|') && t.endsWith('|')) {
      flush();
      final rows = <List<String>>[];
      while (i < lines.length) {
        final r = lines[i].trim();
        if (!(r.startsWith('|') && r.endsWith('|'))) break;
        final cells = r
            .substring(1, r.length - 1)
            .split('|')
            .map((c) => c.trim())
            .toList();
        if (!cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) {
          rows.add(cells);
        }
        i++;
      }
      final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
      blocks.add(
        DesignBlock(
          DesignKind.table,
          cells: [
            for (final r in rows) [...r, ...List.filled(width - r.length, '')],
            if (rows.length == 1) List.filled(width, ''),
          ],
        ),
      );
      continue;
    }
    if (t.startsWith(':::')) {
      flush();
      blocks.add(_directive(t));
      i++;
      continue;
    }
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(t);
    if (heading != null) {
      flush();
      blocks.add(
        DesignBlock(
          DesignKind.heading,
          text: heading.group(2)!,
          level: heading.group(1)!.length,
        ),
      );
      i++;
      continue;
    }
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(t)) {
      flush();
      blocks.add(DesignBlock(DesignKind.divider));
      i++;
      continue;
    }
    if (t.startsWith('>')) {
      flush();
      final quote = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        quote.add(lines[i].trim().substring(1).trimLeft());
        i++;
      }
      blocks.add(DesignBlock(DesignKind.quote, text: quote.join('\n')));
      continue;
    }
    // A line that is only `![alt](url)` — same as :::image for the designer.
    final aloneImage = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)$')
        .firstMatch(t);
    if (aloneImage != null) {
      flush();
      blocks.add(DesignBlock(DesignKind.image, url: aloneImage.group(2)!));
      i++;
      continue;
    }
    final list = bullet.hasMatch(line)
        ? (bullet, DesignKind.bullets)
        : number.hasMatch(line)
        ? (number, DesignKind.numbers)
        : null;
    if (list != null) {
      flush();
      final (pattern, kind) = list;
      final items = <String>[];
      while (i < lines.length && pattern.hasMatch(lines[i])) {
        items.add(pattern.firstMatch(lines[i])!.group(1)!);
        i++;
      }
      blocks.add(DesignBlock(kind, items: items));
      continue;
    }
    para.add(line);
    i++;
  }
  flush();
  return blocks;
}

DesignBlock _directive(String line) {
  final dir = line.substring(3).trim();
  final space = dir.indexOf(' ');
  final name = (space > 0 ? dir.substring(0, space) : dir).toLowerCase();
  final rest = space > 0 ? dir.substring(space + 1).trim() : '';
  switch (name) {
    case 'image':
    case 'video':
    case 'audio':
      return DesignBlock(DesignKind.values.byName(name), url: rest);
    case 'card':
      final s = rest.indexOf(' ');
      final kind = (s > 0 ? rest.substring(0, s) : rest).toLowerCase();
      return DesignBlock(
        DesignKind.card,
        cardKind: designCardKinds.any((k) => k.$1 == kind) ? kind : 'user',
        target: s > 0 ? rest.substring(s + 1).trim() : '',
      );
    case 'chart':
      try {
        final data = jsonDecode(rest.substring(rest.indexOf('{')));
        if (data is Map) {
          final labels = (data['labels'] as List? ?? const []);
          final values = (data['values'] as List? ?? const []);
          return DesignBlock(
            DesignKind.chart,
            chartType: '${data['type'] ?? 'bar'}' == 'line' ? 'line' : 'bar',
            points: [
              for (var n = 0; n < values.length; n++)
                (n < labels.length ? '${labels[n]}' : '', '${values[n]}'),
            ],
          );
        }
      } catch (_) {}
  }
  return DesignBlock(DesignKind.raw, text: line);
}

/// A text field's controller that shows its markdown as it will look: bold
/// runs bold, links tinted, mentions highlighted, with the marks themselves
/// faded, so formatting reads without a preview while staying plain text.
class MarkupTextController extends TextEditingController {
  MarkupTextController({super.text});

  static final _pattern = RegExp(
    r'(\*\*)(.+?)(\*\*)' // bold
    r'|(~~)(.+?)(~~)' // strike
    r'|(`)([^`]+)(`)' // code
    r'|(\[)([^\]]+)(\]\([^)]*\))' // link
    r'|(?<![\w*])(\*)([^*\n]+)(\*)(?!\*)' // italic
    r'|(?<![\w])(_)([^_\n]+)(_)(?![\w])' // italic
    r'|(@[\w.-]+)',
  ); // mention

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final base = style ?? const TextStyle();
    final mark = base.copyWith(color: scheme.outline);
    final source = text;
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _pattern.allMatches(source)) {
      if (m.start > at) {
        spans.add(TextSpan(text: source.substring(at, m.start)));
      }
      if (m.group(19) != null) {
        spans.add(
          TextSpan(
            text: m.group(19),
            style: base.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      } else {
        // Find which alternative matched: groups come in threes.
        for (var g = 1; g < 19; g += 3) {
          if (m.group(g) == null) continue;
          final inner = switch (g) {
            1 => base.copyWith(fontWeight: FontWeight.w800),
            4 => base.copyWith(decoration: TextDecoration.lineThrough),
            7 => base.copyWith(
              fontFamily: 'monospace',
              color: scheme.primary,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
            10 => base.copyWith(
              color: scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary.withValues(alpha: .5),
            ),
            _ => base.copyWith(fontStyle: FontStyle.italic),
          };
          spans
            ..add(TextSpan(text: m.group(g), style: mark))
            ..add(TextSpan(text: m.group(g + 1), style: inner))
            ..add(TextSpan(text: m.group(g + 2), style: mark));
          break;
        }
      }
      at = m.end;
    }
    if (at < source.length) spans.add(TextSpan(text: source.substring(at)));
    return TextSpan(style: base, children: spans);
  }

  /// Wraps the selection in [left] and [right], or unwraps it when it is
  /// already wrapped. With nothing selected, inserts the marks around
  /// [placeholder] and selects it.
  void toggleWrap(String left, String right, {String placeholder = 'text'}) {
    final t = text;
    var sel = selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: t.length);
    final start = sel.start, end = sel.end;
    // Unwrap a selection whose marks sit just outside it…
    if (start >= left.length &&
        end + right.length <= t.length &&
        t.substring(start - left.length, start) == left &&
        t.substring(end, end + right.length) == right) {
      value = TextEditingValue(
        text:
            t.substring(0, start - left.length) +
            t.substring(start, end) +
            t.substring(end + right.length),
        selection: TextSelection(
          baseOffset: start - left.length,
          extentOffset: end - left.length,
        ),
      );
      return;
    }
    // …or inside it.
    final selected = t.substring(start, end);
    if (selected.length >= left.length + right.length &&
        selected.startsWith(left) &&
        selected.endsWith(right)) {
      final inner = selected.substring(
        left.length,
        selected.length - right.length,
      );
      value = TextEditingValue(
        text: t.substring(0, start) + inner + t.substring(end),
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + inner.length,
        ),
      );
      return;
    }
    final inner = selected.isEmpty ? placeholder : selected;
    value = TextEditingValue(
      text: t.substring(0, start) + left + inner + right + t.substring(end),
      selection: TextSelection(
        baseOffset: start + left.length,
        extentOffset: start + left.length + inner.length,
      ),
    );
  }

  /// Replaces the selection with [snippet] and puts the caret after it.
  void insert(String snippet) {
    final t = text;
    var sel = selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: t.length);
    value = TextEditingValue(
      text: t.substring(0, sel.start) + snippet + t.substring(sel.end),
      selection: TextSelection.collapsed(offset: sel.start + snippet.length),
    );
  }

  /// The selected text ("" when nothing is selected).
  String get selectedText {
    final sel = selection;
    if (!sel.isValid || sel.isCollapsed) return '';
    return text.substring(sel.start, sel.end);
  }
}
