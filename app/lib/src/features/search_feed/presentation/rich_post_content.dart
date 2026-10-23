import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/code_highlight.dart';
import '../../../shared/widgets/network_content_image.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../rooms/presentation/widgets/audio_bubble.dart';
import '../../rooms/presentation/widgets/video_bubble.dart';
import 'rich_post_parser.dart';

/// What a post links to inside the app. The app points [openAccount] at its
/// profile panel once it has one, so a forwarded post's author opens from
/// wherever the post shows (the feed, a chat).
abstract final class PostLinks {
  static void Function(BuildContext context, String accountId, String handle)?
      openAccount;

  /// Opens the profile of [accountId] (known as [handle]) when the app can.
  static void open(BuildContext context, String accountId, String handle) {
    if (accountId.isEmpty) return;
    openAccount?.call(context, accountId, handle);
  }
}

/// Renders an extended-markdown post body into styled, professional widgets:
/// formatted text, headings, lists, quotes, code, tables, images, video, audio,
/// charts and user/agent/tool/space cards.
class RichPostContent extends StatelessWidget {
  const RichPostContent(this.source,
      {super.key,
      this.headers = const {},
      this.resolveUrl,
      this.onLinkTap});

  final String source;
  final Map<String, String> headers;

  /// Turns a markup media address (file id, `/v1/files/…`, relative path)
  /// into an absolute URL the network image/player can load.
  final String Function(String url)? resolveUrl;
  final Future<void> Function(String link)? onLinkTap;

  String _url(String raw) => resolveUrl?.call(raw) ?? raw;

  @override
  Widget build(BuildContext context) {
    final blocks = parseRichMarkdown(source);
    if (blocks.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final block in blocks)
        _BlockView(block,
            headers: headers, resolveUrl: _url, onLinkTap: onLinkTap),
    ]);
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView(this.block,
      {required this.headers, required this.resolveUrl, this.onLinkTap});
  final PostBlock block;
  final Map<String, String> headers;
  final String Function(String url) resolveUrl;
  final Future<void> Function(String link)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (block.kind) {
      case BlockKind.heading:
        final level = block.level ?? 2;
        final size = level == 1
            ? 20.0
            : level == 2
                ? 17.0
                : level == 3
                    ? 15.0
                    : 13.5;
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text.rich(
              _inline(context, block.inline.first,
                  onLinkTap: onLinkTap,
                  headers: headers,
                  resolveUrl: resolveUrl,
                  fontSize: size),
              style: TextStyle(
                  fontSize: size,
                  fontWeight: FontWeight.w900,
                  color: scheme.onSurface,
                  height: 1.3)),
        );
      case BlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text.rich(
              _inline(context, block.inline.first,
                  onLinkTap: onLinkTap,
                  headers: headers,
                  resolveUrl: resolveUrl),
              style: const TextStyle(fontSize: 12.5, height: 1.5)),
        );
      case BlockKind.bulletList:
      case BlockKind.orderedList:
        return Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 6),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < block.inline.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          block.kind == BlockKind.bulletList
                              ? '•  '
                              : '${i + 1}.  ',
                          style: const TextStyle(fontSize: 12.5)),
                      Expanded(
                          child: Text.rich(
                              _inline(context, block.inline[i],
                                  onLinkTap: onLinkTap,
                                  headers: headers,
                                  resolveUrl: resolveUrl),
                              style: const TextStyle(
                                  fontSize: 12.5, height: 1.45))),
                    ]),
              ),
          ]),
        );
      case BlockKind.quote:
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: Border(left: BorderSide(color: scheme.primary, width: 3)),
          ),
          child: Text.rich(
              _inline(context, block.inline.first,
                  onLinkTap: onLinkTap,
                  headers: headers,
                  resolveUrl: resolveUrl),
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant)),
        );
      case BlockKind.code:
        final brightness = Theme.of(context).brightness;
        final palette = CodeHighlight.palette(brightness);
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: CodeHighlight.background(brightness),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (block.language.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(block.language,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: palette['comment'])),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text.rich(
                  TextSpan(
                      children: CodeHighlight.spans(
                          block.code ?? '', block.language, palette)),
                  style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                      height: 1.4,
                      color: palette['root'])),
            ),
          ]),
        );
      case BlockKind.divider:
        return Divider(
            height: 20, color: scheme.outlineVariant.withValues(alpha: .5));
      case BlockKind.table:
        final rows = block.rows ?? const [];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: .5))),
          child: Table(
            columnWidths: const {},
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (var r = 0; r < rows.length; r++)
                TableRow(
                  decoration: r == 0
                      ? BoxDecoration(
                          color: scheme.primary.withValues(alpha: .12))
                      : null,
                  children: [
                    for (var c = 0; c < rows[r].length; c++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        child: Text.rich(
                            _inline(context, [rows[r][c]],
                                onLinkTap: onLinkTap,
                                headers: headers,
                                resolveUrl: resolveUrl),
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: r == 0
                                    ? FontWeight.w800
                                    : FontWeight.w500)),
                      ),
                  ],
                ),
            ],
          ),
        );
      case BlockKind.chart:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ChartWidget(block.chart ?? const {}),
        );
      case BlockKind.image:
        final raw = block.url ?? '';
        if (raw.isEmpty) return const SizedBox.shrink();
        final url = resolveUrl(raw);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: NetworkContentImage(
                url: url,
                headers: headers,
                fit: BoxFit.fitWidth,
                alignment: Alignment.center,
                errorBuilder: (_, __, ___) =>
                    _mediaFallback(Icons.image_outlined, 'Image · $raw'),
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const SkeletonBox(
                        width: double.infinity, height: 180, radius: 0),
                width: double.infinity),
          ),
        );
      case BlockKind.video:
        final raw = block.url ?? '';
        if (raw.isEmpty) return const SizedBox.shrink();
        final url = resolveUrl(raw);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: LayoutBuilder(
              builder: (context, box) => VideoBubble(
                  url: url,
                  headers: mediaRequestHeaders(url, headers),
                  radius: 12,
                  width: box.maxWidth.isFinite ? box.maxWidth : 320)),
        );
      case BlockKind.audio:
        final raw = block.url ?? '';
        if (raw.isEmpty) return const SizedBox.shrink();
        final url = resolveUrl(raw);
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12)),
          child: LayoutBuilder(
              builder: (context, box) => AudioBubble(
                  url: url,
                  headers: mediaRequestHeaders(url, headers),
                  mime: '',
                  durationLabel: 'audio',
                  voice: false,
                  width: box.maxWidth.isFinite
                      ? (box.maxWidth - 60).clamp(120.0, 420.0)
                      : 220)),
        );
      case BlockKind.card:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _InfoCard(block.card ?? const PostCard(CardKind.user, '')),
        );
      case BlockKind.forward:
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _ForwardedPost(block.data ?? const {},
              headers: headers,
              resolveUrl: resolveUrl,
              onLinkTap: onLinkTap),
        );
    }
  }

}

Widget _mediaFallback(IconData icon, String label) =>
    Builder(builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return Container(
        height: 140,
        alignment: Alignment.center,
        color: scheme.surfaceContainerHighest,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 30, color: scheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        ]),
      );
    });

/// Builds a rich [TextSpan] from inline tokens.
InlineSpan _inline(
  BuildContext context,
  List<InlineToken> tokens, {
  Future<void> Function(String)? onLinkTap,
  Map<String, String> headers = const {},
  String Function(String url)? resolveUrl,
  double fontSize = 12.5,
}) {
  final scheme = Theme.of(context).colorScheme;
  return TextSpan(children: [
    for (final t in tokens)
      _tokenSpan(context, t, scheme,
          onLinkTap: onLinkTap,
          headers: headers,
          resolveUrl: resolveUrl,
          fontSize: fontSize),
  ]);
}

InlineSpan _tokenSpan(
  BuildContext context,
  InlineToken t,
  ColorScheme scheme, {
  Future<void> Function(String)? onLinkTap,
  Map<String, String> headers = const {},
  String Function(String url)? resolveUrl,
  double fontSize = 12.5,
}) {
  // A heading's runs keep its size.
  final base =
      TextStyle(fontSize: fontSize, height: 1.5, color: scheme.onSurface);
  switch (t.kind) {
    case InlineKind.bold:
      return TextSpan(
          text: t.text, style: base.copyWith(fontWeight: FontWeight.w900));
    case InlineKind.italic:
      return TextSpan(
          text: t.text, style: base.copyWith(fontStyle: FontStyle.italic));
    case InlineKind.strike:
      return TextSpan(
          text: t.text,
          style: base.copyWith(
              decoration: TextDecoration.lineThrough,
              color: scheme.onSurfaceVariant));
    case InlineKind.code:
      return TextSpan(
          text: t.text,
          style: base.copyWith(
              fontFamily: 'monospace',
              fontSize: fontSize - 1,
              color: scheme.primary,
              backgroundColor: scheme.surfaceContainerHighest));
    case InlineKind.link:
      return WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: () async {
              if (onLinkTap != null) {
                await onLinkTap(t.href ?? '');
                return;
              }
              final uri = Uri.tryParse(t.href ?? '');
              if (uri != null) {
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } catch (_) {}
              }
            },
            child: Text('${t.text} ↗',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary.withValues(alpha: .5))),
          ));
    case InlineKind.mention:
      return TextSpan(
          text: t.text,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: scheme.primary));
    case InlineKind.image:
      final raw = t.href ?? '';
      if (raw.isEmpty) return TextSpan(text: t.text, style: base);
      final url = resolveUrl?.call(raw) ?? raw;
      return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: NetworkContentImage(
                  url: url,
                  headers: headers,
                  width: 220,
                  fit: BoxFit.fitWidth,
                  errorBuilder: (_, __, ___) => _mediaFallback(
                      Icons.image_outlined, 'Image · $raw')),
            ),
          ));
    case InlineKind.text:
      return TextSpan(text: t.text, style: base);
  }
}

/// A small chart rendered from a `:::chart {json}` directive. Supports
/// `bar` and `line` charts with optional labels.
class _ChartWidget extends StatelessWidget {
  const _ChartWidget(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = (data['type'] as String? ?? 'bar').toLowerCase();
    final labels =
        (data['labels'] as List?)?.cast<String>() ?? const <String>[];
    final raw = data['values'] as List? ?? const <dynamic>[];
    final values = raw.whereType<num>().map((n) => n.toDouble()).toList();
    if (values.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: .5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
              type == 'line'
                  ? Icons.show_chart_rounded
                  : Icons.bar_chart_rounded,
              size: 16,
              color: scheme.primary),
          const SizedBox(width: 6),
          Text(type == 'line' ? 'Line chart' : 'Bar chart',
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 110,
          child: CustomPaint(
            size: const Size(double.infinity, 110),
            painter: _ChartPainter(
                type: type, values: values, color: scheme.primary),
          ),
        ),
        if (labels.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(children: [
            for (final l in labels)
              Expanded(
                child: Text(l,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 8)),
              ),
          ]),
        ],
      ]),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(
      {required this.type, required this.values, required this.color});
  final String type;
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.fold<double>(0, (a, b) => b > a ? b : a);
    final max = maxV <= 0 ? 1.0 : maxV;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final step = size.width / values.length;
    if (type == 'line') {
      final points = [
        for (var i = 0; i < values.length; i++)
          Offset(step * i + step / 2,
              size.height - (values[i] / max) * (size.height - 8)),
      ];
      final line = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        line.lineTo(p.dx, p.dy);
      }
      final area = Path.from(line)
        ..lineTo(points.last.dx, size.height)
        ..lineTo(points.first.dx, size.height)
        ..close();
      canvas.drawPath(area, Paint()..color = color.withValues(alpha: .14));
      canvas.drawPath(
          line,
          paint
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round);
      for (final p in points) {
        canvas.drawCircle(p, 3, Paint()..color = color);
      }
      return;
    }
    final barWidth = size.width / values.length * 0.5;
    for (var i = 0; i < values.length; i++) {
      final h = (values[i] / max) * (size.height - 8);
      final x = step * i + step / 2;
      final rect =
          Rect.fromLTWH(x - barWidth / 2, size.height - h, barWidth, h);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.values != values || old.color != color || old.type != type;
}

/// Renders a `:::card` directive as a themed info card.
class _InfoCard extends StatelessWidget {
  const _InfoCard(this.card);
  final PostCard card;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, title) = switch (card.kind) {
      CardKind.user => (Icons.person_rounded, AppColors.cyan, 'Trader'),
      CardKind.agent => (Icons.smart_toy_rounded, AppColors.primary, 'Agent'),
      CardKind.tool => (Icons.apps_rounded, AppColors.warning, 'App'),
      CardKind.space => (Icons.hub_rounded, AppColors.success, 'Workspace'),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: .35))),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
              color: color.withValues(alpha: .16),
              borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w800,
                    color: color)),
            const SizedBox(height: 2),
            Text(card.target,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800)),
          ]),
        ),
        Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
      ]),
    );
  }
}

/// A feed post shared into a chat (a `:::post` directive): a "Forwarded
/// from" tag naming its author, who opens on a tap, over the post itself.
class _ForwardedPost extends StatelessWidget {
  const _ForwardedPost(this.data,
      {required this.headers, required this.resolveUrl, this.onLinkTap});
  final Map<String, dynamic> data;
  final Map<String, String> headers;
  final String Function(String url) resolveUrl;
  final Future<void> Function(String link)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final authorId = '${data['author_id'] ?? ''}';
    final handle = '${data['handle'] ?? ''}';
    final name = '${data['name'] ?? ''}'.isNotEmpty
        ? '${data['name']}'
        : handle.isNotEmpty
            ? '@$handle'
            : 'a post';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ForwardedTag(
          name: name,
          handle: handle,
          avatar: '${data['avatar'] ?? ''}',
          onTap: authorId.isEmpty
              ? null
              : () => PostLinks.open(context, authorId, handle),
        ),
        const SizedBox(height: 8),
        RichPostContent('${data['body'] ?? ''}',
            headers: headers,
            resolveUrl: resolveUrl,
            onLinkTap: onLinkTap),
      ]),
    );
  }
}

/// The "Forwarded from" tag of a shared post: the original author's picture
/// and name; tapping it opens their profile.
class ForwardedTag extends StatelessWidget {
  const ForwardedTag(
      {super.key,
      required this.name,
      this.handle = '',
      this.avatar = '',
      this.onTap});
  final String name;
  final String handle;
  final String avatar;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = (handle.isNotEmpty ? handle : name)
        .replaceAll('@', '')
        .characters
        .take(1)
        .toString()
        .toUpperCase();
    return Tooltip(
      message: onTap == null ? '' : 'Open ${handle.isEmpty ? name : '@$handle'}',
      child: Material(
        color: scheme.primary.withValues(alpha: .1),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 3, 10, 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              CircleAvatar(
                radius: 10,
                backgroundColor: scheme.primary.withValues(alpha: .2),
                foregroundImage: Avatars.of(avatar),
                onForegroundImageError:
                    avatar.isEmpty ? null : (_, __) {},
                child: Text(initial,
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary)),
              ),
              const SizedBox(width: 6),
              Icon(Icons.shortcut_rounded, size: 14, color: scheme.primary),
              const SizedBox(width: 4),
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: 'Forwarded from ',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    TextSpan(
                        text: name,
                        style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w800)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
