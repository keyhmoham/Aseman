/// Parses the platform's extended markdown dialect into renderable blocks.
///
/// Beyond standard markdown (headings, bold/italic/strike, inline code, links,
/// lists, quotes, code fences, tables, images) it understands block directives
/// for rich content:
///
/// ```text
/// :::image https://…/photo.png
/// :::chart {"type":"bar","labels":["A","B"],"values":[1,2]}
/// :::video https://…/clip.mp4
/// :::audio https://…/note.mp3
/// :::card user @handle
/// :::card agent AgentName
/// :::card tool ToolName
/// :::card space WorkspaceName
/// :::post {"id":"…","author_id":"…","name":"…","handle":"…","body":"…"}
/// ```
///
/// A line that is only a standard markdown image (`![alt](url)`) is also a
/// block image, so posts and messages authored that way render the same as
/// `:::image`.
///
/// `:::post` is a feed post shared into a chat: it shows as a card naming the
/// post's author, who can be opened from it.
///
/// Posts store this as a plain markdown string; the client renders it with
/// [RichPostContent]. Post bodies remain portable markdown so anything that
/// reads the raw string sees clean markup.
library;

import 'dart:convert' show JsonDecoder, jsonEncode;

enum InlineKind { text, bold, italic, strike, code, link, image, mention }

class InlineToken {
  const InlineToken(this.kind, this.text, {this.href});
  final InlineKind kind;
  final String text;
  final String? href;
}

enum BlockKind {
  paragraph,
  heading,
  bulletList,
  orderedList,
  quote,
  callout,
  code,
  divider,
  table,
  chart,
  image,
  video,
  audio,
  card,
  forward,
}

/// The type of a `:::card` directive (user / agent / tool / space).
enum CardKind { user, agent, tool, space }

class PostCard {
  const PostCard(this.kind, this.target);
  final CardKind kind;
  final String target;
}

class PostBlock {
  const PostBlock(this.kind, this.inline,
      {this.level,
      this.code,
      this.language = '',
      this.tone = '',
      this.rows,
      this.cells,
      this.chart,
      this.url,
      this.card,
      this.data});
  final BlockKind kind;

  /// Inline tokens for paragraph/heading/list/quote/callout lines.
  final List<List<InlineToken>> inline;
  final int? level;
  final String? code;

  /// A code block's language, from its fence (```python).
  final String language;

  /// A callout's tone: note, tip, important, warning, caution.
  final String tone;

  /// Table rows as a flat token list (previews). Prefer [cells] to draw.
  final List<List<InlineToken>>? rows;

  /// Table rows, each a list of cells.
  final List<List<List<InlineToken>>>? cells;
  final Map<String, dynamic>? chart;
  final String? url;
  final PostCard? card;

  /// A `:::post` directive's post: its id, its author's account id, name,
  /// handle and picture, and its body.
  final Map<String, dynamic>? data;
}

/// Splits the raw markdown string into [PostBlock]s.
List<PostBlock> parseRichMarkdown(String source) {
  final blocks = <PostBlock>[];
  final lines = source.split('\n');
  var inFence = false;
  final fenceBuf = <String>[];
  var fenceLanguage = '';
  final paragraphBuf = <String>[];

  void flushParagraph() {
    if (paragraphBuf.isEmpty) return;
    blocks.add(
        PostBlock(BlockKind.paragraph, [parseInline(paragraphBuf.join('\n'))]));
    paragraphBuf.clear();
  }

  // Table accumulation.
  final tableRows = <String>[];
  void flushTable() {
    if (tableRows.isEmpty) return;
    final flat = <List<InlineToken>>[];
    final grid = <List<List<InlineToken>>>[];
    for (var i = 0; i < tableRows.length; i++) {
      if (i == 1 && _isTableSeparator(tableRows[i])) continue;
      var parts = tableRows[i].split('|').map((c) => c.trim()).toList();
      if (parts.isNotEmpty && parts.first.isEmpty) {
        parts = parts.sublist(1);
      }
      if (parts.isNotEmpty && parts.last.isEmpty) {
        parts = parts.sublist(0, parts.length - 1);
      }
      if (parts.isEmpty) continue;
      final rowCells = [for (final part in parts) parseInline(part)];
      grid.add(rowCells);
      flat.add([
        for (final cell in rowCells)
          InlineToken(InlineKind.text, cell.map((t) => t.text).join()),
      ]);
    }
    if (grid.isNotEmpty) {
      blocks.add(PostBlock(BlockKind.table, const [], rows: flat, cells: grid));
    }
    tableRows.clear();
  }

  void emitFence(String language, String code) {
    final chart = chartFence(language, code);
    if (chart != null) {
      blocks.add(PostBlock(BlockKind.chart, const [], chart: chart));
      return;
    }
    blocks.add(PostBlock(BlockKind.code, const [],
        code: code, language: language));
  }

  void flushFence() {
    if (!inFence || fenceBuf.isEmpty) return;
    emitFence(fenceLanguage, fenceBuf.join('\n'));
    fenceBuf.clear();
  }

  for (final raw in lines) {
    final line = raw.trimRight();

    // Code fence.
    if (line.trimLeft().startsWith('```')) {
      if (inFence) {
        emitFence(fenceLanguage, fenceBuf.join('\n'));
        fenceBuf.clear();
        inFence = false;
      } else {
        flushParagraph();
        flushTable();
        inFence = true;
        fenceLanguage =
            line.trimLeft().substring(3).trim().split(RegExp(r'\s')).first;
      }
      continue;
    }
    if (inFence) {
      fenceBuf.add(line);
      continue;
    }

    // Tables.
    if (line.trimLeft().startsWith('|') && line.trimRight().endsWith('|')) {
      flushParagraph();
      tableRows.add(line);
      continue;
    } else {
      flushTable();
    }

    final trimmed = line.trim();

    // Blank line → paragraph break.
    if (trimmed.isEmpty) {
      flushParagraph();
      continue;
    }

    // Directives.
    if (trimmed.startsWith(':::')) {
      flushParagraph();
      final dir = trimmed.substring(3).trim();
      final space = dir.indexOf(' ');
      final kind = (space > 0 ? dir.substring(0, space) : dir).toLowerCase();
      final rest = (space > 0 ? dir.substring(space + 1) : '').trim();
      switch (kind) {
        case 'chart':
          blocks.add(PostBlock(BlockKind.chart, const [], chart: _json(rest)));
          break;
        case 'image':
          blocks.add(PostBlock(BlockKind.image, const [], url: rest));
          break;
        case 'video':
          blocks.add(PostBlock(BlockKind.video, const [], url: rest));
          break;
        case 'audio':
          blocks.add(PostBlock(BlockKind.audio, const [], url: rest));
          break;
        case 'card':
          blocks.add(PostBlock(BlockKind.card, const [], card: _card(rest)));
          break;
        case 'post':
          blocks.add(PostBlock(BlockKind.forward, const [], data: _json(rest)));
          break;
      }
      continue;
    }

    // A line that is only `![alt](url)` → block image (same as :::image).
    final aloneImage = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)$')
        .firstMatch(trimmed);
    if (aloneImage != null) {
      flushParagraph();
      blocks.add(
          PostBlock(BlockKind.image, const [], url: aloneImage.group(2)!));
      continue;
    }

    // A line that is only a link to a picture, clip or audio file.
    final aloneLink =
        RegExp(r'^\[([^\]]*)\]\((https?:[^)\s]+)\)$').firstMatch(trimmed);
    if (aloneLink != null) {
      final kind = _mediaKind(aloneLink.group(2)!);
      if (kind != null) {
        flushParagraph();
        blocks.add(PostBlock(kind, const [], url: aloneLink.group(2)!));
        continue;
      }
    }

    // Headings.
    final hMatch = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (hMatch != null) {
      flushParagraph();
      blocks.add(PostBlock(BlockKind.heading, [parseInline(hMatch.group(2)!)],
          level: hMatch.group(1)!.length));
      continue;
    }

    // Horizontal rule.
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
      flushParagraph();
      blocks.add(const PostBlock(BlockKind.divider, []));
      continue;
    }

    // Blockquote. Consecutive lines are joined afterwards, so a callout
    // (`> [!WARNING]`) keeps the lines under it.
    if (trimmed.startsWith('>')) {
      flushParagraph();
      blocks.add(PostBlock(
          BlockKind.quote, [parseInline(trimmed.substring(1).trim())]));
      continue;
    }

    // Lists.
    if (RegExp(r'^[-*+]\s+').hasMatch(trimmed)) {
      flushParagraph();
      blocks.add(PostBlock(BlockKind.bulletList,
          [parseInline(trimmed.replaceFirst(RegExp(r'^[-*+]\s+'), ''))]));
      continue;
    }
    if (RegExp(r'^\d+\.\s+').hasMatch(trimmed)) {
      flushParagraph();
      blocks.add(PostBlock(BlockKind.orderedList,
          [parseInline(trimmed.replaceFirst(RegExp(r'^\d+\.\s+'), ''))]));
      continue;
    }

    // Plain paragraph line.
    paragraphBuf.add(line);
  }
  flushParagraph();
  flushFence();
  flushTable();
  return _joinQuotes(blocks);
}

/// Consecutive quote lines are one quote. A first line `[!NOTE]` (and the
/// other GitHub tones) is a callout card instead.
List<PostBlock> _joinQuotes(List<PostBlock> blocks) {
  final out = <PostBlock>[];
  var i = 0;
  while (i < blocks.length) {
    if (blocks[i].kind != BlockKind.quote) {
      out.add(blocks[i]);
      i++;
      continue;
    }
    final lines = <List<InlineToken>>[];
    while (i < blocks.length && blocks[i].kind == BlockKind.quote) {
      lines.addAll(blocks[i].inline);
      i++;
    }
    final first = lines.isEmpty ? '' : lines.first.map((t) => t.text).join();
    final call = RegExp(
            r'^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$',
            caseSensitive: false)
        .firstMatch(first.trim());
    if (call == null) {
      out.add(PostBlock(BlockKind.quote, lines));
      continue;
    }
    final rest = call.group(2)!.trim();
    final body = <List<InlineToken>>[
      if (rest.isNotEmpty) parseInline(rest),
      ...lines.skip(1),
    ];
    out.add(PostBlock(BlockKind.callout, body, tone: call.group(1)!.toLowerCase()));
  }
  return out;
}

BlockKind? _mediaKind(String href) {
  final path = href.split(RegExp(r'[?#]')).first;
  if (RegExp(r'\.(png|jpe?g|gif|webp|avif|bmp|svg)$', caseSensitive: false)
      .hasMatch(path)) {
    return BlockKind.image;
  }
  if (RegExp(r'\.(mp4|webm|mov|m4v)$', caseSensitive: false).hasMatch(path)) {
    return BlockKind.video;
  }
  if (RegExp(r'\.(mp3|m4a|wav|ogg|aac|flac)$', caseSensitive: false)
      .hasMatch(path)) {
    return BlockKind.audio;
  }
  return null;
}

/// A fenced `chart` / `bar` or `line` / `spark` block: `Label: 12` per line,
/// optional `title: …`. Null when the fence is ordinary code.
Map<String, dynamic>? chartFence(String lang, String text) {
  final type = switch (lang.trim().toLowerCase()) {
    'chart' || 'bar' || 'bars' => 'bar',
    'line' || 'spark' || 'sparkline' => 'line',
    _ => null,
  };
  if (type == null) return null;
  var title = '';
  final labels = <String>[];
  final values = <num>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final titled = RegExp(r'^(?:title)\s*[:=]\s*(.+)$', caseSensitive: false)
        .firstMatch(line);
    if (titled != null && values.isEmpty) {
      title = titled.group(1)!.trim();
      continue;
    }
    final pair =
        RegExp(r'^([^:|,]+)\s*[:,|]\s*(-?\d+(?:\.\d+)?)\s*$').firstMatch(line);
    if (pair == null) return null;
    labels.add(pair.group(1)!.trim());
    values.add(num.parse(pair.group(2)!));
  }
  if (values.length < (type == 'line' ? 2 : 1)) return null;
  return {
    'type': type,
    if (title.isNotEmpty) 'title': title,
    'labels': labels,
    'values': values,
  };
}

/// Parses inline formatting into tokens (bold, italic, strike, code, links,
/// images, mentions). Falls back to treating the whole run as text on error.
List<InlineToken> parseInline(String source) {
  final out = <InlineToken>[];
  var i = 0;
  final buf = StringBuffer();
  void flushText() {
    if (buf.isNotEmpty) {
      out.add(InlineToken(InlineKind.text, buf.toString()));
      buf.clear();
    }
  }

  while (i < source.length) {
    final ch = source[i];
    // Images ![alt](url)
    if (ch == '!' && i + 1 < source.length && source[i + 1] == '[') {
      final close = source.indexOf('](', i + 2);
      final end = close < 0 ? -1 : source.indexOf(')', close + 2);
      if (close >= 0 && end >= 0) {
        flushText();
        out.add(InlineToken(InlineKind.image, source.substring(i + 2, close),
            href: source.substring(close + 2, end)));
        i = end + 1;
        continue;
      }
    }
    // Links [label](url)
    if (ch == '[') {
      final close = source.indexOf('](', i + 1);
      final end = close < 0 ? -1 : source.indexOf(')', close + 2);
      if (close >= 0 && end >= 0) {
        flushText();
        out.add(InlineToken(InlineKind.link, source.substring(i + 1, close),
            href: source.substring(close + 2, end)));
        i = end + 1;
        continue;
      }
    }
    // Mentions @handle
    if (ch == '@') {
      final m = RegExp(r'^@[\w.-]+').firstMatch(source.substring(i));
      if (m != null) {
        flushText();
        out.add(InlineToken(InlineKind.mention, m.group(0)!));
        i += m.group(0)!.length;
        continue;
      }
    }
    // Bold **text**
    if (ch == '*' && i + 1 < source.length && source[i + 1] == '*') {
      final close = source.indexOf('**', i + 2);
      if (close >= 0) {
        flushText();
        out.add(InlineToken(InlineKind.bold, source.substring(i + 2, close)));
        i = close + 2;
        continue;
      }
    }
    // Italic *text*
    if (ch == '*') {
      final close = source.indexOf('*', i + 1);
      if (close >= 0) {
        flushText();
        out.add(InlineToken(InlineKind.italic, source.substring(i + 1, close)));
        i = close + 1;
        continue;
      }
    }
    // Bold __text__ and italic _text_, at word edges only (snake_case
    // stays as it is).
    if (ch == '_' && (i == 0 || !_word(source[i - 1]))) {
      final strong = i + 1 < source.length && source[i + 1] == '_';
      final mark = strong ? '__' : '_';
      final close = source.indexOf(mark, i + mark.length + 1);
      if (close >= 0 &&
          (close + mark.length >= source.length ||
              !_word(source[close + mark.length]))) {
        flushText();
        out.add(InlineToken(strong ? InlineKind.bold : InlineKind.italic,
            source.substring(i + mark.length, close)));
        i = close + mark.length;
        continue;
      }
    }
    // Strike ~~text~~
    if (ch == '~' && i + 1 < source.length && source[i + 1] == '~') {
      final close = source.indexOf('~~', i + 2);
      if (close >= 0) {
        flushText();
        out.add(InlineToken(InlineKind.strike, source.substring(i + 2, close)));
        i = close + 2;
        continue;
      }
    }
    // Inline code `code`
    if (ch == '`') {
      final close = source.indexOf('`', i + 1);
      if (close >= 0) {
        flushText();
        out.add(InlineToken(InlineKind.code, source.substring(i + 1, close)));
        i = close + 1;
        continue;
      }
    }
    buf.write(ch);
    i++;
  }
  flushText();
  return out.isEmpty ? [InlineToken(InlineKind.text, source)] : out;
}

bool _word(String ch) => RegExp(r'[A-Za-z0-9_]').hasMatch(ch);

Map<String, dynamic> _json(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return const {};
  try {
    final decoded = const JsonDecoder().convert(raw.substring(start, end + 1));
    return decoded is Map<String, dynamic> ? decoded : const {};
  } catch (_) {
    return const {};
  }
}

PostCard _card(String rest) {
  final space = rest.indexOf(' ');
  final kind = (space > 0 ? rest.substring(0, space) : rest).toLowerCase();
  final target = (space > 0 ? rest.substring(space + 1) : '').trim();
  final k = switch (kind) {
    'agent' => CardKind.agent,
    'tool' => CardKind.tool,
    'space' => CardKind.space,
    _ => CardKind.user,
  };
  return PostCard(
      k, target.isEmpty ? (k == CardKind.user ? '@person' : 'Entity') : target);
}

bool _isTableSeparator(String line) {
  final cells = line.split('|');
  var hasSep = false;
  for (final c in cells) {
    final t = c.trim();
    if (t.isEmpty) continue;
    if (RegExp(r'^:?-{2,}:?$').hasMatch(t)) {
      hasSep = true;
    } else {
      return false;
    }
  }
  return hasSep;
}

/// The `:::post` directive that shares a feed post into a chat: it carries
/// the post's id, its author ([authorId], [name], [handle], [avatar]) and its
/// [body], so the chat shows it as a card with a "Forwarded from" tag.
String forwardedPostMarkup({
  required String id,
  required String authorId,
  required String body,
  String name = '',
  String handle = '',
  String avatar = '',
}) =>
    ':::post ${jsonEncode({
      'id': id,
      'author_id': authorId,
      if (name.isNotEmpty) 'name': name,
      if (handle.isNotEmpty) 'handle': handle,
      if (avatar.isNotEmpty) 'avatar': avatar,
      'body': body,
    })}';

/// Caps nested `:::post` / forward expansion so a hostile or cyclic body
/// cannot blow the stack while a chat-list tile is building (release
/// ErrorWidget = grey box under the Chats chrome).
const _markupPreviewMaxDepth = 6;

/// A one-line, plain-text summary of a markup [source] for chat lists and
/// notifications: directives become words ("Forwarded post", "Chart") and
/// markup characters are dropped.
///
/// Never throws: chat tiles call this during [State.build], and an exception
/// here becomes Flutter's grey [ErrorWidget] for the whole list row.
String markupPreview(String source, {int depth = 0}) {
  if (depth > _markupPreviewMaxDepth) {
    return _plainPreviewFallback(source);
  }
  try {
    final parts = <String>[];
    for (final b in parseRichMarkdown(source)) {
      final text = switch (b.kind) {
        BlockKind.forward => () {
            final d = b.data ?? const {};
            final who = '${d['name'] ?? ''}'.isNotEmpty
                ? '${d['name']}'
                : '${d['handle'] ?? ''}'.isNotEmpty
                    ? '@${d['handle']}'
                    : '';
            final inner =
                markupPreview('${d['body'] ?? ''}', depth: depth + 1);
            return [
              'Forwarded post${who.isEmpty ? '' : ' from $who'}',
              if (inner.isNotEmpty) inner,
            ].join(': ');
          }(),
        BlockKind.chart => 'Chart',
        BlockKind.callout => [
            b.tone,
            for (final run in b.inline) run.map((t) => t.text).join(),
          ].join(' '),
        BlockKind.image => 'Photo',
        BlockKind.video => 'Video',
        BlockKind.audio => 'Audio',
        BlockKind.card => b.card?.target ?? '',
        BlockKind.divider => '',
        BlockKind.code => b.code ?? '',
        BlockKind.table => [
            for (final row in b.rows ?? const <List<InlineToken>>[])
              row.map((t) => t.text).join(' '),
          ].join(' '),
        _ => [
            for (final run in b.inline) run.map((t) => t.text).join(),
          ].join(' '),
      };
      if (text.trim().isNotEmpty) parts.add(text.trim());
    }
    return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  } catch (_) {
    return _plainPreviewFallback(source);
  }
}

String _plainPreviewFallback(String source) {
  var text = source.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length > 160) text = '${text.substring(0, 160)}…';
  return text;
}

/// The readable text of a markup [source], one block per paragraph, for
/// sharing a post outside the app.
String markupPlainText(String source) {
  String run(List<InlineToken> r) => r.map((t) => t.text).join();
  return [
    for (final b in parseRichMarkdown(source))
      switch (b.kind) {
        BlockKind.bulletList => b.inline.map((r) => '• ${run(r)}').join('\n'),
        BlockKind.orderedList => [
            for (var i = 0; i < b.inline.length; i++)
              '${i + 1}. ${run(b.inline[i])}'
          ].join('\n'),
        BlockKind.quote || BlockKind.callout =>
          '“${b.inline.map(run).join(' ')}”',
        BlockKind.image || BlockKind.video || BlockKind.audio => b.url ?? '',
        BlockKind.code => b.code ?? '',
        BlockKind.table =>
          (b.rows ?? const <List<InlineToken>>[])
              .map((r) => r.map((t) => t.text).join(' · '))
              .join('\n'),
        BlockKind.card => b.card?.target ?? '',
        BlockKind.forward => markupPlainText('${b.data?['body'] ?? ''}'),
        BlockKind.chart || BlockKind.divider => '',
        _ => b.inline.map(run).join('\n'),
      },
  ].where((l) => l.trim().isNotEmpty).join('\n\n');
}
