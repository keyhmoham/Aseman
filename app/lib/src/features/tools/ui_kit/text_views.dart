/// Text views: markdown, a log viewer, a diff viewer and a QR code.
library;

import 'dart:math' as math;
import '../../../core/theme/app_shape.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_widgets.dart' show KitOn;
import 'palette.dart';
import 'qr_encoder.dart';
import 'structured_views.dart' show CodeBlock;
import 'values.dart';

// ── inline markdown ─────────────────────────────────────────────────────────

final RegExp _inline = RegExp(
  r'(\*\*|__)(.+?)\1' // bold
  r'|~~(.+?)~~' // strike
  r'|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\*)' // *italic*
  r'|(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])' // _italic_
  r'|`([^`]+)`' // code
  r'|\[([^\]]+)\]\(([^)\s]+)\)' // [link](url)
  r'|(https?://[^\s)]+)', // bare url
);

/// Spans of [text] with **bold**, *italic*, ~~strike~~, `code` and links;
/// [onLink] receives a tapped link (recognizers are added to [recognizers]
/// so the owner can dispose them).
List<InlineSpan> inlineSpans(String text, TextStyle base, VizPalette p,
    {void Function(String href)? onLink, List<GestureRecognizer>? recognizers}) {
  final out = <InlineSpan>[];
  var last = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start), style: base));
    if (m.group(2) != null) {
      out.addAll(inlineSpans(m.group(2)!, base.copyWith(fontWeight: FontWeight.w700), p, onLink: onLink, recognizers: recognizers));
    } else if (m.group(3) != null) {
      out.addAll(inlineSpans(m.group(3)!, base.copyWith(decoration: TextDecoration.lineThrough), p, onLink: onLink, recognizers: recognizers));
    } else if (m.group(4) != null || m.group(5) != null) {
      out.addAll(inlineSpans(m.group(4) ?? m.group(5)!, base.copyWith(fontStyle: FontStyle.italic), p, onLink: onLink, recognizers: recognizers));
    } else if (m.group(6) != null) {
      out.add(TextSpan(
          text: ' ${m.group(6)} ',
          style: base.copyWith(fontFamily: 'monospace', fontSize: (base.fontSize ?? 14) * 0.92, backgroundColor: p.scheme.surfaceContainerHighest)));
    } else {
      final label = m.group(7) ?? m.group(9)!;
      final href = m.group(8) ?? m.group(9)!;
      final rec = onLink == null ? null : (TapGestureRecognizer()..onTap = () => onLink(href));
      if (rec != null) recognizers?.add(rec);
      out.add(TextSpan(text: label, style: base.copyWith(color: p.scheme.primary, decoration: TextDecoration.underline, decorationColor: p.scheme.primary), recognizer: rec));
    }
    last = m.end;
  }
  if (last < text.length) out.add(TextSpan(text: text.substring(last), style: base));
  return out;
}

// ── Markdown ────────────────────────────────────────────────────────────────

/// Markdown: headings, paragraphs, bullet / numbered / task lists (nested),
/// quotes, fenced code (highlighted), tables, rules, images and inline
/// styles. A tapped link fires `link` `{href}` (or opens it when the node
/// has no handler).
class KitMarkdown extends StatefulWidget {
  const KitMarkdown({super.key, required this.props, required this.on});
  final Map<String, dynamic> props;
  final KitOn on;

  @override
  State<KitMarkdown> createState() => _KitMarkdownState();
}

class _KitMarkdownState extends State<KitMarkdown> {
  final List<GestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _link(String href) {
    final emit = widget.on('link');
    if (emit != null) return emit('link', {'href': href});
    final uri = Uri.tryParse(href);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'mailto')) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final p = VizPalette.of(context);
    final body = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(height: 1.55, color: s.onSurface);
    final dense = widget.props['size'] == 'compact';
    final lines = asText(widget.props['text'] ?? widget.props['content'] ?? widget.props['markdown']).replaceAll('\r\n', '\n').split('\n');
    final blocks = <Widget>[];
    Widget rich(String t, TextStyle style, {TextAlign? align}) =>
        Text.rich(TextSpan(children: inlineSpans(t, style, p, onLink: _link, recognizers: _recognizers)), textAlign: align);
    final para = <String>[];
    void flush() {
      if (para.isEmpty) return;
      blocks.add(rich(para.join(' ').trim(), body));
      para.clear();
    }

    final listRe = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?(.*)$');
    final tableSep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');
    List<String> cellsOf(String row) {
      var r = row.trim();
      if (r.startsWith('|')) r = r.substring(1);
      if (r.endsWith('|')) r = r.substring(0, r.length - 1);
      return r.split('|').map((c) => c.trim()).toList();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fence = RegExp(r'^\s*```\s*([\w+-]*)\s*$').firstMatch(line);
      if (fence != null) {
        flush();
        final code = <String>[];
        for (i++; i < lines.length && !RegExp(r'^\s*```\s*$').hasMatch(lines[i]); i++) {
          code.add(lines[i]);
        }
        blocks.add(CodeBlock(props: {'code': code.join('\n'), 'language': fence.group(1)!.isEmpty ? null : fence.group(1)}));
        continue;
      }
      final h = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$').firstMatch(line);
      if (h != null) {
        flush();
        final level = h.group(1)!.length;
        final style = (switch (level) {
          1 => theme.textTheme.headlineSmall,
          2 => theme.textTheme.titleLarge,
          3 => theme.textTheme.titleMedium,
          _ => theme.textTheme.titleSmall,
        })!
            .copyWith(fontWeight: level <= 2 ? FontWeight.w800 : FontWeight.w700, color: s.onSurface, height: 1.3);
        blocks.add(Padding(padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : (level <= 2 ? 10 : 4)), child: rich(h.group(2)!, style)));
        continue;
      }
      if (RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$').hasMatch(line)) {
        flush();
        blocks.add(Divider(color: s.outlineVariant, height: 16));
        continue;
      }
      final img = RegExp(r'^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*$').firstMatch(line);
      if (img != null) {
        flush();
        blocks.add(ClipRRect(
          borderRadius: AppShape.borderRadius(context, 16),
          child: Image.network(img.group(2)!, fit: BoxFit.cover, semanticLabel: img.group(1), errorBuilder: (_, __, ___) => Text(img.group(1)!, style: body.copyWith(color: s.onSurfaceVariant))),
        ));
        continue;
      }
      if (line.trimLeft().startsWith('>')) {
        flush();
        final quote = <String>[];
        for (; i < lines.length && lines[i].trimLeft().startsWith('>'); i++) {
          quote.add(lines[i].trimLeft().replaceFirst(RegExp(r'^>\s?'), ''));
        }
        i--;
        blocks.add(Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(color: s.surfaceContainerHigh, borderRadius: AppShape.borderRadius(context, 16), border: Border(left: BorderSide(color: s.primary, width: 3))),
          child: rich(quote.join(' '), body.copyWith(color: s.onSurfaceVariant, fontStyle: FontStyle.italic)),
        ));
        continue;
      }
      if (line.contains('|') && i + 1 < lines.length && tableSep.hasMatch(lines[i + 1])) {
        flush();
        final head = cellsOf(line);
        final rows = <List<String>>[];
        for (i += 2; i < lines.length && lines[i].contains('|') && lines[i].trim().isNotEmpty; i++) {
          rows.add(cellsOf(lines[i]));
        }
        i--;
        blocks.add(ClipRRect(
          borderRadius: AppShape.borderRadius(context, 16),
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: s.outlineVariant), borderRadius: AppShape.borderRadius(context, 16)),
            child: Table(
              defaultColumnWidth: const FlexColumnWidth(),
              border: TableBorder(horizontalInside: BorderSide(color: s.outlineVariant.withValues(alpha: .6))),
              children: [
                TableRow(decoration: BoxDecoration(color: s.surfaceContainerHigh), children: [
                  for (final c in head) Padding(padding: const EdgeInsets.all(10), child: rich(c, body.copyWith(fontWeight: FontWeight.w700))),
                ]),
                for (final r in rows)
                  TableRow(children: [
                    for (var k = 0; k < head.length; k++) Padding(padding: const EdgeInsets.all(10), child: rich(k < r.length ? r[k] : '', body)),
                  ]),
              ],
            ),
          ),
        ));
        continue;
      }
      final li = listRe.firstMatch(line);
      if (li != null) {
        flush();
        final items = <Widget>[];
        for (; i < lines.length; i++) {
          final m = listRe.firstMatch(lines[i]);
          if (m == null) {
            // A continuation line of the last item.
            if (lines[i].trim().isNotEmpty && lines[i].startsWith('  ') && items.isNotEmpty) continue;
            break;
          }
          final depth = (m.group(1)!.replaceAll('\t', '  ').length ~/ 2).clamp(0, 4);
          final marker = m.group(2)!;
          final task = m.group(3);
          final done = task != null && task.toLowerCase().contains('x');
          final bullet = task != null
              ? Icon(done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 18, color: done ? s.primary : s.onSurfaceVariant)
              : (RegExp(r'^\d').hasMatch(marker)
                  ? Text('${marker.replaceAll(')', '.')} ', style: body.copyWith(color: s.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]))
                  : Padding(
                      padding: const EdgeInsets.only(top: 9, right: 2),
                      child: Container(width: 6, height: 6, decoration: BoxDecoration(color: depth == 0 ? s.primary : s.onSurfaceVariant, shape: depth == 0 ? BoxShape.circle : BoxShape.rectangle)),
                    ));
          items.add(Padding(
            padding: EdgeInsets.only(left: 18.0 * depth, top: 2, bottom: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 22, child: Align(alignment: Alignment.topLeft, child: bullet)),
              Expanded(child: rich(m.group(4)!, done ? body.copyWith(decoration: TextDecoration.lineThrough, color: s.onSurfaceVariant) : body)),
            ]),
          ));
        }
        i--;
        blocks.add(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items));
        continue;
      }
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      para.add(line);
      if (line.endsWith('  ')) flush();
    }
    flush();
    return LayoutBuilder(builder: (context, box) {
      final col = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        for (var k = 0; k < blocks.length; k++) Padding(padding: EdgeInsets.only(top: k == 0 ? 0 : (dense ? 6 : 10)), child: blocks[k]),
      ]);
      return box.maxWidth.isFinite ? col : SizedBox(width: 480, child: col);
    });
  }
}

// ── LogView ─────────────────────────────────────────────────────────────────

final RegExp _levelRe = RegExp(r'^\s*(?:(\S+T\S+|\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?)\s+)?\[?(TRACE|DEBUG|INFO|NOTICE|WARN|WARNING|ERROR|ERR|FATAL|CRITICAL|SUCCESS|OK)\]?:?\s+(.*)$', caseSensitive: false);

/// Log lines (strings, or `{time, level, message, source}`) in a monospace
/// panel, each level colored, following the end as lines arrive.
class KitLogView extends StatefulWidget {
  const KitLogView({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  State<KitLogView> createState() => _KitLogViewState();
}

class _KitLogViewState extends State<KitLogView> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final p = VizPalette.of(context);
    final lines = <(String?, String?, String, String?)>[];
    for (final l in asList(widget.props['lines'] ?? widget.props['data'])) {
      if (l is Map) {
        final m = asMap(l);
        lines.add((m['time'] == null ? null : asText(m['time']), m['level'] == null ? null : asText(m['level']), asText(m['message'] ?? m['text'] ?? m['msg']), m['source'] == null ? null : asText(m['source'])));
      } else {
        final t = asText(l);
        final m = _levelRe.firstMatch(t);
        lines.add(m == null ? (null, null, t, null) : (m.group(1), m.group(2), m.group(3)!, null));
      }
    }
    final filter = widget.props['filter'] == null ? null : asText(widget.props['filter']).toLowerCase();
    final shown = filter == null ? lines : lines.where((l) => '${l.$2} ${l.$3} ${l.$4}'.toLowerCase().contains(filter)).toList();
    Color levelColor(String? lv) => switch (lv?.toLowerCase()) {
          'error' || 'err' || 'fatal' || 'critical' => VizPalette.critical,
          'warn' || 'warning' => VizPalette.warning,
          'success' || 'ok' => VizPalette.good,
          'debug' || 'trace' => p.textMuted,
          null => p.textMuted,
          _ => p.accent,
        };
    final mono = TextStyle(fontFamily: 'monospace', fontSize: asDouble(widget.props['fontSize'], 12.5), height: 1.45, color: s.onSurface);
    final wrap = asBool(widget.props['wrap'], true);
    final showTime = asBool(widget.props['showTime'], true);
    final numbers = asBool(widget.props['lineNumbers']);
    if (asBool(widget.props['follow'], true)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (final (i, l) in shown.indexed)
        Container(
          color: ['error', 'err', 'fatal', 'critical'].contains(l.$2?.toLowerCase()) ? VizPalette.critical.withValues(alpha: .08) : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
          child: Text.rich(
            TextSpan(children: [
              if (numbers) TextSpan(text: '${(i + 1).toString().padLeft(4)}  ', style: mono.copyWith(color: p.textMuted)),
              if (showTime && l.$1 != null) TextSpan(text: '${l.$1}  ', style: mono.copyWith(color: p.textMuted)),
              if (l.$2 != null) TextSpan(text: '${l.$2!.toUpperCase().padRight(5)} ', style: mono.copyWith(color: levelColor(l.$2), fontWeight: FontWeight.w700)),
              if (l.$4 != null) TextSpan(text: '${l.$4}: ', style: mono.copyWith(color: s.tertiary)),
              TextSpan(text: l.$3),
            ]),
            style: mono,
            softWrap: wrap,
          ),
        ),
      if (shown.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(asText(widget.props['emptyText'] ?? 'No log lines'), style: mono.copyWith(color: p.textMuted))),
    ]);
    final maxH = asSize(widget.props['maxHeight'], 320);
    return Container(
      decoration: BoxDecoration(color: s.surfaceContainerHighest.withValues(alpha: .6), borderRadius: AppShape.borderRadius(context, 16)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (widget.props['title'] != null)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            color: s.surfaceContainerHigh,
            child: Row(children: [
              Icon(Icons.terminal_rounded, size: 16, color: s.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(asText(widget.props['title']), style: theme.textTheme.labelLarge)),
              Text('${shown.length} lines', style: theme.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant)),
            ]),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: wrap ? content : SingleChildScrollView(scrollDirection: Axis.horizontal, child: content),
          ),
        ),
      ]),
    );
  }
}

// ── DiffView ────────────────────────────────────────────────────────────────

class _DLine {
  const _DLine(this.kind, this.oldNo, this.newNo, this.text);

  /// ' ' same, '-' removed, '+' added.
  final String kind;
  final int? oldNo, newNo;
  final String text;
}

/// The line diff of [a] → [b] (longest common subsequence).
List<_DLine> _diff(List<String> a, List<String> b) {
  if (a.length * b.length > 4000000) {
    return [
      for (var i = 0; i < a.length; i++) _DLine('-', i + 1, null, a[i]),
      for (var j = 0; j < b.length; j++) _DLine('+', null, j + 1, b[j]),
    ];
  }
  final n = a.length, m = b.length;
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  final out = <_DLine>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(_DLine(' ', i + 1, j + 1, a[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add(_DLine('-', i + 1, null, a[i]));
      i++;
    } else {
      out.add(_DLine('+', null, j + 1, b[j]));
      j++;
    }
  }
  for (; i < n; i++) {
    out.add(_DLine('-', i + 1, null, a[i]));
  }
  for (; j < m; j++) {
    out.add(_DLine('+', null, j + 1, b[j]));
  }
  return out;
}

/// The line-by-line difference between `before` and `after` (or a unified
/// `diff`): additions and removals on tonal green and red, unchanged runs
/// folded to `context` lines (tap to expand), a +/− summary.
class KitDiffView extends StatefulWidget {
  const KitDiffView({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  State<KitDiffView> createState() => _KitDiffViewState();
}

class _KitDiffViewState extends State<KitDiffView> {
  final Set<int> _open = {};

  List<_DLine> _lines() {
    final unified = widget.props['diff'];
    if (unified is String) {
      final out = <_DLine>[];
      var o = 0, n = 0;
      for (final l in unified.split('\n')) {
        final h = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)').firstMatch(l);
        if (h != null) {
          o = int.parse(h.group(1)!) - 1;
          n = int.parse(h.group(2)!) - 1;
          continue;
        }
        if (l.startsWith('+++') || l.startsWith('---') || l.startsWith('diff ') || l.startsWith('index ')) continue;
        if (l.startsWith('+')) {
          out.add(_DLine('+', null, ++n, l.substring(1)));
        } else if (l.startsWith('-')) {
          out.add(_DLine('-', ++o, null, l.substring(1)));
        } else {
          out.add(_DLine(' ', ++o, ++n, l.startsWith(' ') ? l.substring(1) : l));
        }
      }
      return out;
    }
    return _diff(asText(widget.props['before'] ?? widget.props['old']).split('\n'), asText(widget.props['after'] ?? widget.props['new']).split('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final p = VizPalette.of(context);
    final lines = _lines();
    final ctx = asInt(widget.props['context'], 3);
    final adds = lines.where((l) => l.kind == '+').length, dels = lines.where((l) => l.kind == '-').length;
    // Fold unchanged runs longer than 2 × context.
    final rows = <Object>[]; // _DLine or (start, count)
    for (var i = 0; i < lines.length;) {
      if (lines[i].kind != ' ') {
        rows.add(lines[i++]);
        continue;
      }
      var j = i;
      while (j < lines.length && lines[j].kind == ' ') {
        j++;
      }
      final head = i == 0 ? 0 : ctx, tail = j == lines.length ? 0 : ctx;
      if (j - i > head + tail + 1 && !_open.contains(i)) {
        rows.addAll(lines.sublist(i, i + head));
        rows.add((i + head, j - i - head - tail, i));
        rows.addAll(lines.sublist(j - tail, j));
      } else {
        rows.addAll(lines.sublist(i, j));
      }
      i = j;
    }
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.5, color: s.onSurface);
    final addBg = VizPalette.good.withValues(alpha: p.dark ? .18 : .12), delBg = VizPalette.critical.withValues(alpha: p.dark ? .18 : .1);
    String no(int? n) => (n == null ? '' : '$n').padLeft(4);
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (final r in rows)
        if (r is _DLine)
          Container(
            color: r.kind == '+' ? addBg : (r.kind == '-' ? delBg : null),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '${no(r.oldNo)} ${no(r.newNo)} ', style: mono.copyWith(color: p.textMuted)),
                TextSpan(text: r.kind == ' ' ? '  ' : '${r.kind} ', style: mono.copyWith(color: r.kind == '+' ? VizPalette.good : (r.kind == '-' ? VizPalette.critical : null), fontWeight: FontWeight.w700)),
                TextSpan(text: r.text),
              ]),
              style: mono,
              softWrap: true,
            ),
          )
        else if (r case (int _, int count, int start))
          InkWell(
            onTap: () => setState(() => _open.add(start)),
            child: Container(
              color: s.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              child: Row(children: [
                Icon(Icons.unfold_more_rounded, size: 16, color: s.primary),
                const SizedBox(width: 8),
                Text('$count unchanged lines', style: theme.textTheme.labelMedium?.copyWith(color: s.primary)),
              ]),
            ),
          ),
    ]);
    return Container(
      decoration: BoxDecoration(border: Border.all(color: s.outlineVariant), borderRadius: AppShape.borderRadius(context, 16)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          color: s.surfaceContainerHigh,
          child: Row(children: [
            Icon(Icons.difference_rounded, size: 16, color: s.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(asText(widget.props['title'] ?? widget.props['file'] ?? 'Changes'), overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge?.copyWith(fontFamily: 'monospace'))),
            Text('+$adds', style: theme.textTheme.labelLarge?.copyWith(color: VizPalette.good, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('−$dels', style: theme.textTheme.labelLarge?.copyWith(color: VizPalette.critical, fontWeight: FontWeight.w700)),
          ]),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: asSize(widget.props['maxHeight'], 480)),
          child: SingleChildScrollView(padding: const EdgeInsets.symmetric(vertical: 4), child: body),
        ),
      ]),
    );
  }
}

// ── QR code ─────────────────────────────────────────────────────────────────

/// A QR code of `data` (a URL, text, a ticket id), in the theme's ink on a
/// light rounded tile (dark-on-light keeps it scannable in dark mode too).
class KitQrCode extends StatelessWidget {
  const KitQrCode({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = VizPalette.of(context);
    final data = asText(props['data'] ?? props['value'] ?? props['text'] ?? props['url']);
    final size = asDouble(props['size'], 160).clamp(64, 600).toDouble();
    QrCode? qr;
    String? error;
    try {
      qr = data.isEmpty ? null : QrCode.encode(data, ecc: QrEcc.parse(props['ecc']));
    } catch (e) {
      error = 'Too long for a QR code';
    }
    final ink = p.parse(props['color']) ?? const Color(0xFF111111);
    final tile = Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.06),
      decoration: BoxDecoration(color: p.parse(props['background']) ?? Colors.white, borderRadius: BorderRadius.circular(size * 0.1)),
      child: qr == null
          ? Center(child: Text(error ?? 'No data', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54)))
          : CustomPaint(painter: _QrPainter(qr, ink, asBool(props['rounded'], true))),
    );
    return Semantics(
      label: 'QR code: $data',
      image: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        tile,
        if (props['label'] != null) ...[
          const SizedBox(height: 8),
          Text(asText(props['label']), style: theme.textTheme.labelLarge),
        ],
      ]),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.qr, this.ink, this.rounded);
  final QrCode qr;
  final Color ink;
  final bool rounded;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide / qr.size;
    final paint = Paint()..color = ink..isAntiAlias = true;
    bool finder(int x, int y) => (x < 7 && y < 7) || (x >= qr.size - 7 && y < 7) || (x < 7 && y >= qr.size - 7);
    for (var y = 0; y < qr.size; y++) {
      for (var x = 0; x < qr.size; x++) {
        if (!qr.dark(x, y) || (rounded && finder(x, y))) continue;
        final r = Rect.fromLTWH(x * cell, y * cell, cell + 0.4, cell + 0.4);
        if (rounded) {
          canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(cell * 0.06), Radius.circular(cell * 0.3)), paint);
        } else {
          canvas.drawRect(r, paint);
        }
      }
    }
    if (!rounded) return;
    // Finder patterns as rounded squares (still scannable: same geometry).
    for (final (fx, fy) in [(0, 0), (qr.size - 7, 0), (0, qr.size - 7)]) {
      final o = Offset(fx * cell, fy * cell);
      canvas.drawRRect(RRect.fromRectAndRadius(o & Size(7 * cell, 7 * cell), Radius.circular(cell * 2)), paint);
      canvas.drawRRect(RRect.fromRectAndRadius((o + Offset(cell, cell)) & Size(5 * cell, 5 * cell), Radius.circular(cell * 1.4)), Paint()..color = Colors.white);
      canvas.drawRRect(RRect.fromRectAndRadius((o + Offset(2 * cell, 2 * cell)) & Size(3 * cell, 3 * cell), Radius.circular(cell)), paint);
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.qr != qr || old.ink != ink;
}
