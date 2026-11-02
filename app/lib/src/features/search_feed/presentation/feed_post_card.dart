import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/mini_tag.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../../shared/widgets/spark_painter.dart';
import '../domain/feed_post.dart';
import 'comments_sheet.dart';
import 'post_actions.dart';
import 'post_editor.dart';
import 'post_media_grid.dart';
import 'rich_post_content.dart';
import 'rich_post_parser.dart';
import 'search_feed_view_model.dart' show compactCount;
import 'share_post_sheet.dart';

/// A post as the feed shows it: its author (or, for a shared post, who
/// shared it with a "Forwarded from" tag naming the original author), its
/// rich content and media, its tags, likes, comments and sharing. Its menu
/// lets the author edit or delete it and everyone else report it.
class FeedPostCard extends StatefulWidget {
  const FeedPostCard({
    super.key,
    required this.post,
    required this.dependencies,
    this.onToggleLike,
    this.onEdited,
    this.onDeleted,
    this.onShared,
  });
  final FeedPost post;
  final AppDependencies dependencies;
  final VoidCallback? onToggleLike;

  /// Called with the new body once the author saved an edit.
  final ValueChanged<String>? onEdited;

  /// Called once the author deleted the post.
  final VoidCallback? onDeleted;

  /// Called once the post was shared into a feed or chat.
  final VoidCallback? onShared;

  @override
  State<FeedPostCard> createState() => _FeedPostCardState();
}

class _FeedPostCardState extends State<FeedPostCard> {
  bool _busy = false;

  /// How many comments the post has once its comments panel counted them.
  int? _comments;

  FeedPost get post => widget.post;

  @override
  void didUpdateWidget(FeedPostCard old) {
    super.didUpdateWidget(old);
    if (old.post.serverId != post.serverId ||
        old.post.comments != post.comments) {
      _comments = null;
    }
  }

  bool get _mine {
    final me = widget.dependencies.sessionController.session?.accountId ?? '';
    return me.isNotEmpty && me == post.authorId;
  }

  void _snack(String message) => ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: markupPlainText(post.body)));
    _snack('Text copied');
  }

  Future<void> _share() async {
    if (post.serverId == null) {
      await sharePostExternally(context, post);
      return;
    }
    final shared =
        await showSharePostSheet(context, widget.dependencies, post);
    if ((shared ?? 0) > 0) widget.onShared?.call();
  }

  Future<void> _openComments() => showCommentsSheet(
      context, widget.dependencies, post,
      onCount: (n) {
        if (mounted) setState(() => _comments = n);
      });

  Future<void> _edit() async {
    final id = post.serverId;
    if (id == null) return;
    final body = await showPostEditor(context,
        initial: post.body, title: 'Edit post', publishLabel: 'Save');
    if (body == null || body.trim().isEmpty || body.trim() == post.body) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.dependencies.service.updatePost(id, body.trim());
      widget.onEdited?.call(body.trim());
      _snack('Post updated');
    } catch (e) {
      _snack('Could not update the post: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final id = post.serverId;
    if (id == null || !await confirmDeletePost(context)) return;
    setState(() => _busy = true);
    try {
      await widget.dependencies.service.deletePost(id);
      widget.onDeleted?.call();
      _snack('Post deleted');
    } catch (e) {
      _snack('Could not delete the post: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report() async {
    final id = post.serverId;
    if (id == null) return;
    final report = await showReportPostDialog(context);
    if (report == null) return;
    try {
      await widget.dependencies.service
          .reportPost(id, reason: report.reason, note: report.note);
      _snack('Thanks — the admins will review this post');
    } catch (e) {
      _snack('Could not report the post: $e');
    }
  }

  void _openAuthor() => PostLinks.open(
      context, post.authorId, post.handle.replaceFirst('@', ''));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final server = post.serverId != null;
    final accent = post.color;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      // Soft portal surface — no BackdropFilter; Opacity is safe here.
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: _busy ? .55 : 1,
        child: SoftCard(
          accent: accent,
          secondary: scheme.primary,
          radius: AppShape.card - 2,
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.md - 2, AppSpacing.sm, AppSpacing.sm),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  InkWell(
                    onTap: post.authorId.isEmpty ? null : _openAuthor,
                    customBorder: const CircleBorder(),
                    child: AppAvatar(post.initials,
                        color: accent,
                        radius: 22,
                        avatar: post.avatar,
                        identity: post.authorId),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                      child: InkWell(
                    onTap: post.authorId.isEmpty ? null : _openAuthor,
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Flexible(
                                child: Text(post.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                        ))),
                            if (post.verified) ...[
                              const SizedBox(width: 5),
                              Icon(Icons.verified_rounded,
                                  size: 16, color: scheme.primary),
                            ],
                          ]),
                          const SizedBox(height: 1),
                          Text(
                              [
                                post.handle,
                                post.time,
                                if (post.edited) 'edited',
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: scheme.onSurfaceVariant)),
                        ]),
                  )),
                  if (post.pinned)
                    SoftMetaChip(
                      label: 'Pinned',
                      icon: Icons.push_pin_rounded,
                      accent: scheme.primary,
                    ),
                  _menu(scheme, server),
                ]),
                if (post.isForward) ...[
                  const SizedBox(height: AppSpacing.sm - 2),
                  ForwardedTag(
                    name: post.forwardName,
                    handle: post.forwardHandle,
                    avatar: post.forwardAvatar,
                    authorId: post.forwardAuthorId,
                    onTap: post.forwardAuthorId.isEmpty
                        ? null
                        : () => PostLinks.open(context, post.forwardAuthorId,
                            post.forwardHandle),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: DefaultTextStyle.merge(
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                height: 1.45,
                                fontSize: 15,
                              ) ??
                          const TextStyle(fontSize: 15, height: 1.45),
                      child: RichPostContent(post.body,
                          headers: widget.dependencies.service.authHeaders(),
                          resolveUrl:
                              widget.dependencies.service.resolveContentUrl)),
                ),
                if (post.media.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  PostMediaGrid(
                      media: post.media,
                      resolveUrl: (f) =>
                          widget.dependencies.service.fileContentUrl(f.id),
                      headers: widget.dependencies.service.authHeaders(),
                      download: (f) =>
                          widget.dependencies.service.downloadFile(f.id)),
                ],
                if (post.chart) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                      height: 96,
                      clipBehavior: Clip.antiAlias,
                      decoration: softSurfaceDecoration(
                        scheme,
                        accent: accent,
                        secondary: scheme.primary,
                        radius: AppShape.inner,
                      ),
                      child: Stack(fit: StackFit.expand, children: [
                        CustomPaint(
                            painter: SparkPainter(accent),
                            child: const SizedBox.expand()),
                        Positioned(
                            left: 12,
                            top: 10,
                            child: MiniTag(post.coin ?? 'CHART', accent))
                      ])),
                ],
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SoftMetaChip(label: post.tag, accent: accent),
                    if (post.workspace != null)
                      SoftMetaChip(
                        label: post.workspace!.toUpperCase(),
                        accent: AppColors.primary,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm - 2),
                Divider(height: 1, color: AppSurfaces.cardBorder(scheme)),
                const SizedBox(height: AppSpacing.xs),
                Row(children: [
                  Expanded(
                    child: Wrap(spacing: 6, runSpacing: 6, children: [
                      _PostAction(
                        icon: post.liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        label: post.likes,
                        tooltip: post.liked ? 'Unlike' : 'Like',
                        active: post.liked,
                        activeColor: Colors.pinkAccent,
                        onTap: widget.onToggleLike,
                      ),
                      _PostAction(
                          icon: Icons.chat_bubble_outline_rounded,
                          label: _comments == null
                              ? post.comments
                              : compactCount(_comments!),
                          tooltip: 'Comments',
                          onTap: server ? _openComments : null),
                      _PostAction(
                          icon: Icons.shortcut_rounded,
                          label: 'Share',
                          tooltip: 'Share to feeds, chats or other apps',
                          onTap: _share),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Copy text',
                    onPressed: _copy,
                    icon: Icon(Icons.copy_rounded,
                        size: 19, color: scheme.onSurfaceVariant),
                  ),
                ]),
              ]),
        ),
      ),
    );
  }

  Widget _menu(ColorScheme scheme, bool server) {
    PopupMenuItem<String> item(String value, IconData icon, String label,
            {Color? color}) =>
        PopupMenuItem(
            value: value,
            child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(icon, color: color),
                title: Text(label, style: TextStyle(color: color))));
    return AppPopupMenuButton<String>(
      tooltip: 'More',
      enabled: !_busy,
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (v) => switch (v) {
        'copy' => _copy(),
        'share' => _share(),
        'external' => sharePostExternally(context, post),
        'edit' => _edit(),
        'delete' => _delete(),
        'report' => _report(),
        _ => null,
      },
      itemBuilder: (_) => [
        item('share', Icons.shortcut_rounded, 'Share…'),
        item('external', Icons.ios_share_rounded, 'Share to other apps'),
        item('copy', Icons.copy_rounded, 'Copy text'),
        if (server && _mine) ...[
          const PopupMenuDivider(),
          if (!post.isForward) item('edit', Icons.edit_rounded, 'Edit post'),
          item('delete', Icons.delete_outline_rounded, 'Delete post',
              color: scheme.error),
        ] else if (server) ...[
          const PopupMenuDivider(),
          item('report', Icons.flag_outlined, 'Report post',
              color: scheme.error),
        ],
      ],
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
            : AppSurfaces.card(scheme),
        shape: StadiumBorder(
          side: BorderSide(
            color: active
                ? color.withValues(alpha: .28)
                : AppSurfaces.cardBorder(scheme),
          ),
        ),
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
