import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/mini_tag.dart';
import '../../../shared/widgets/spark_painter.dart';
import '../../../shared/widgets/status_tag.dart';
import '../domain/feed_post.dart';
import 'post_media_grid.dart';
import 'rich_post_content.dart';

/// A post as the feed shows it: its author, its rich content and media, its
/// tags, and likes.
class FeedPostCard extends StatelessWidget {
  const FeedPostCard(
      {required this.post, required this.service, this.onToggleLike});
  final FeedPost post;
  final AsemanService service;
  final VoidCallback? onToggleLike;

  void _copy(BuildContext context, String message) {
    Clipboard.setData(ClipboardData(text: post.body));
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShape.card - 2)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 10, 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AppAvatar(post.initials,
                  color: post.color, radius: 22, avatar: post.avatar),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      Flexible(
                          child: Text(post.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700))),
                      if (post.verified) ...[
                        const SizedBox(width: 5),
                        Icon(Icons.verified_rounded,
                            size: 16, color: scheme.primary),
                      ],
                    ]),
                    Text('${post.handle} · ${post.time}',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ])),
              if (post.pinned)
                Icon(Icons.push_pin_rounded, size: 18, color: scheme.primary),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (v) => _copy(
                    context, v == 'share' ? 'Copied to share' : 'Text copied'),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'copy',
                      child: ListTile(
                          leading: Icon(Icons.copy_rounded),
                          title: Text('Copy text'))),
                  PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                          leading: Icon(Icons.ios_share_rounded),
                          title: Text('Share'))),
                ],
              ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 12, 8, 0),
              child: DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 15, height: 1.45),
                  child: RichPostContent(post.body)),
            ),
            if (post.media.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: PostMediaGrid(
                    media: post.media,
                    resolveUrl: (f) => service.fileContentUrl(f.id),
                    headers: service.authHeaders(),
                    download: (f) => service.downloadFile(f.id)),
              ),
            ],
            if (post.chart) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                    height: 96,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [
                          post.color.withValues(alpha: .22),
                          scheme.primaryContainer.withValues(alpha: .16)
                        ]),
                        borderRadius: BorderRadius.circular(AppShape.inner)),
                    child: Stack(fit: StackFit.expand, children: [
                      CustomPaint(
                          painter: SparkPainter(post.color),
                          child: const SizedBox.expand()),
                      Positioned(
                          left: 12,
                          top: 10,
                          child: MiniTag(post.coin ?? 'CHART', post.color))
                    ])),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusTag(post.tag, post.color),
                if (post.workspace != null)
                  MiniTag(post.workspace!.toUpperCase(), AppColors.primary),
              ],
            ),
            const SizedBox(height: 8),
            Row(children: [
              _PostAction(
                icon: post.liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                label: post.likes,
                tooltip: post.liked ? 'Unlike' : 'Like',
                active: post.liked,
                activeColor: Colors.pinkAccent,
                onTap: onToggleLike,
              ),
              const SizedBox(width: 6),
              _PostAction(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: post.comments,
                  tooltip: 'Comments'),
              const Spacer(),
              IconButton(
                tooltip: 'Copy text',
                onPressed: () => _copy(context, 'Text copied'),
                icon: Icon(Icons.copy_rounded,
                    size: 19, color: scheme.onSurfaceVariant),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// A pill-shaped post action with a count, tinted when active.
class _PostAction extends StatelessWidget {
  const _PostAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onTap,
    this.active = false,
    this.activeColor,
  });
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        active ? activeColor ?? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active
            ? color.withValues(alpha: .14)
            : scheme.surfaceContainerHighest.withValues(alpha: .6),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, a) =>
                    ScaleTransition(scale: a, child: child),
                child: Icon(icon, key: ValueKey(icon), size: 18, color: color),
              ),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: color)),
            ]),
          ),
        ),
      ),
    );
  }
}
