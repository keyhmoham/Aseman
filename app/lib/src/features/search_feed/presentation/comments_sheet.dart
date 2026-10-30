import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_dependencies.dart';
import '../../../data/models/post.dart';
import '../../../data/models/profile.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../domain/feed_post.dart';
import 'post_actions.dart';
import 'rich_post_content.dart';
import 'rich_post_parser.dart';
import 'search_feed_view_model.dart' show feedColorFor;
import 'share_post_sheet.dart' show SharePostPreview;

/// Opens the comments of [post]: a centered modal on wide screens and a
/// bottom sheet on phones. Readers like, reply to and report comments, their
/// authors delete them, and anyone signed in adds one from the composer at
/// the bottom. [onCount] hears how many comments the post has whenever that
/// changes.
Future<void> showCommentsSheet(
  BuildContext context,
  AppDependencies dependencies,
  FeedPost post, {
  ValueChanged<int>? onCount,
}) => showAdaptivePanel<void>(
  context,
  CommentsSheet(
    dependencies: dependencies,
    post: post,
    onCount: onCount,
    inBottomSheet: MediaQuery.sizeOf(context).width < 720,
  ),
  breakpoint: 720,
  maxWidth: 600,
  maxHeight: 820,
  heightFactor: .92,
);

class CommentsSheet extends StatefulWidget {
  const CommentsSheet({
    super.key,
    required this.dependencies,
    required this.post,
    this.onCount,
    this.inBottomSheet = false,
  });
  final AppDependencies dependencies;
  final FeedPost post;
  final ValueChanged<int>? onCount;

  /// Body stays clear; [showAppSheet] owns the frosted chrome.
  final bool inBottomSheet;

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  List<SocialPost> _comments = const [];
  bool _loading = true;
  String? _error;
  bool _sending = false;

  /// Ids of comments whose like, or deletion, is on its way to the server.
  final _liking = <String>{};
  final _deleting = <String>{};

  /// The signed-in reader's profile, for their picture and name.
  UserProfile? _myProfile;

  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';
  String get _myHandle =>
      widget.dependencies.sessionController.session?.handle ?? '';
  String get _postId => widget.post.serverId ?? '';

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
    _load();
    _loadMe();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.dependencies.service.fetchComments(_postId);
      if (!mounted) return;
      setState(() {
        _comments = list;
        _loading = false;
      });
      widget.onCount?.call(list.length);
      unawaited(_resolveAuthors());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadMe() async {
    if (_me.isEmpty) return;
    try {
      final me = await widget.dependencies.service.fetchUserProfile(_me);
      if (!mounted) return;
      setState(() => _myProfile = me);
      unawaited(_resolveAuthors());
    } catch (_) {
      // The composer keeps the initials.
    }
  }

  /// Profiles fetched for comment authors the server sent without a name.
  final _authors = <String, Future<UserProfile?>>{};

  /// Fills in the name, handle and picture of every comment whose author
  /// came without them, fetching each author's profile once.
  Future<void> _resolveAuthors() async {
    final missing = {
      for (final c in _comments)
        if ((c.authorName.isEmpty && c.authorHandle.isEmpty) ||
            (c.authorAvatar.isEmpty && c.authorId == _me))
          c.authorId,
    }..remove('');
    if (missing.isEmpty) return;
    final service = widget.dependencies.service;
    final found = <String, UserProfile>{};
    await Future.wait([
      for (final id in missing)
        (_authors[id] ??= id == _me && _myProfile != null
                ? Future.value(_myProfile)
                : service
                      .fetchUserProfile(id)
                      .then<UserProfile?>((p) => p)
                      .catchError((_) => null))
            .then((p) {
              // A failed fetch is tried again the next time.
              if (p == null) _authors.remove(id);
              if (p != null) found[id] = p;
            }),
    ]);
    if (!mounted || found.isEmpty) return;
    setState(() {
      _comments = [
        for (final c in _comments)
          if (found[c.authorId] case final p?) _withAuthor(c, p) else c,
      ];
    });
  }

  static SocialPost _withAuthor(SocialPost c, UserProfile p) => c.copyWith(
    authorName: c.authorName.isNotEmpty ? c.authorName : p.name,
    authorHandle: c.authorHandle.isNotEmpty ? c.authorHandle : p.handle,
    authorAvatar: c.authorAvatar.isNotEmpty ? c.authorAvatar : p.avatar,
  );

  void _snack(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  });

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending || _postId.isEmpty) return;
    setState(() => _sending = true);
    try {
      final id = await widget.dependencies.service.commentPost(_postId, body);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _sending = false;
        _comments = [
          ..._comments,
          SocialPost(
            id: id,
            authorId: _me,
            parentId: _postId,
            authorName: _myProfile?.name ?? _myHandle,
            authorHandle: _myProfile?.handle ?? _myHandle,
            authorAvatar: _myProfile?.avatar ?? '',
            body: body,
            createdAt: DateTime.now(),
          ),
        ];
      });
      widget.onCount?.call(_comments.length);
      _scrollToEnd();
      // Signs it with the reader's profile if that had not loaded yet.
      unawaited(_resolveAuthors());
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Could not post your comment: $e');
    }
  }

  void _replyTo(SocialPost c) {
    if (c.authorHandle.isEmpty) {
      _focus.requestFocus();
      return;
    }
    final mention = '@${c.authorHandle} ';
    if (!_input.text.startsWith(mention)) {
      _input.value = TextEditingValue(
        text: '$mention${_input.text}',
        selection: TextSelection.collapsed(
          offset: mention.length + _input.text.length,
        ),
      );
    }
    _focus.requestFocus();
  }

  void _replace(String id, SocialPost Function(SocialPost) change) =>
      setState(() {
        _comments = [for (final c in _comments) c.id == id ? change(c) : c];
      });

  Future<void> _toggleLike(SocialPost c) async {
    if (_liking.contains(c.id)) return;
    final liked = c.likedByMe;
    _liking.add(c.id);
    _replace(
      c.id,
      (p) => p.withLike(
        likes: liked ? (p.likes > 0 ? p.likes - 1 : 0) : p.likes + 1,
        likedByMe: !liked,
      ),
    );
    try {
      if (liked) {
        await widget.dependencies.service.unlikePost(c.id);
      } else {
        await widget.dependencies.service.likePost(c.id);
      }
    } catch (_) {
      if (mounted) _replace(c.id, (_) => c);
    } finally {
      _liking.remove(c.id);
    }
  }

  Future<void> _delete(SocialPost c) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: const Text('Delete this comment?'),
        content: const Text('It is removed for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting.add(c.id));
    try {
      await widget.dependencies.service.deletePost(c.id);
      if (!mounted) return;
      setState(() {
        _deleting.remove(c.id);
        _comments = _comments.where((p) => p.id != c.id).toList();
      });
      widget.onCount?.call(_comments.length);
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting.remove(c.id));
      _snack('Could not delete the comment: $e');
    }
  }

  Future<void> _report(SocialPost c) async {
    final report = await showReportPostDialog(context);
    if (report == null) return;
    try {
      await widget.dependencies.service.reportPost(
        c.id,
        reason: report.reason,
        note: report.note,
      );
      _snack('Thanks — the admins will review this comment');
    } catch (e) {
      _snack('Could not report the comment: $e');
    }
  }

  Future<void> _copy(SocialPost c) async {
    await Clipboard.setData(ClipboardData(text: markupPlainText(c.body)));
    _snack('Comment copied');
  }

  bool get _loaded => !_loading && _error == null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Sheet / adaptive dialog host paints the glass; keep the body clear.
    final inSheet =
        widget.inBottomSheet || AppSheetScope.inSheetOf(context);
    return Material(
      color: Colors.transparent,
      child: Column(
        children: [
          _header(scheme, inSheet: inSheet),
          Expanded(child: _body(scheme)),
          _composer(scheme),
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme, {required bool inSheet}) => Padding(
    // Sheet chrome already has a drag handle; tighten the title inset.
    padding: EdgeInsets.fromLTRB(20, inSheet ? 4 : 12, 8, 4),
    child: Row(
      children: [
        const Text(
          'Comments',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _loaded
              ? Container(
                  key: ValueKey(_comments.length),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    '${_comments.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );

  Widget _body(ColorScheme scheme) {
    final preview = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SharePostPreview(post: widget.post),
    );
    if (_loading) {
      return ListView(
        physics: const NeverScrollableScrollPhysics(),
        children: [
          preview,
          for (var i = 0; i < 4; i++) _CommentSkeleton(wide: i.isEven),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        children: [
          preview,
          _EmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Comments could not be loaded',
            text: 'Check your connection and try again.',
            action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ),
        ],
      );
    }
    if (_comments.isEmpty) {
      return ListView(
        children: [
          preview,
          _EmptyState(
            icon: Icons.forum_outlined,
            title: 'No comments yet',
            text: 'Start the conversation — be the first to reply.',
            action: TextButton(
              onPressed: _focus.requestFocus,
              child: const Text('Write a comment'),
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: _comments.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) return preview;
          final c = _comments[i - 1];
          return _CommentTile(
            key: ValueKey(c.id),
            comment: c,
            mine: _me.isNotEmpty && c.authorId == _me,
            byPostAuthor: c.authorId == widget.post.authorId,
            busy: _deleting.contains(c.id),
            headers: widget.dependencies.service.authHeaders(),
            resolveUrl: widget.dependencies.service.resolveContentUrl,
            onLike: () => _toggleLike(c),
            onReply: () => _replyTo(c),
            onCopy: () => _copy(c),
            onDelete: () => _delete(c),
            onReport: () => _report(c),
          );
        },
      ),
    );
  }

  Widget _composer(ColorScheme scheme) {
    // A bottom sheet stays above the keyboard itself; a dialog already does.
    final inSheet = ModalRoute.of(context) is ModalBottomSheetRoute;
    final keyboard = inSheet ? MediaQuery.viewInsetsOf(context).bottom : 0.0;
    final canSend = _input.text.trim().isNotEmpty && !_sending;
    return Container(
      padding: EdgeInsets.fromLTRB(12, 10, 12, 12 + keyboard),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: AppAvatar(
                initialsOf(_myProfile?.name ?? _myHandle),
                color: feedColorFor(_me),
                radius: 18,
                avatar: _myProfile?.avatar,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                enabled: _me.isNotEmpty && _postId.isNotEmpty,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: _me.isEmpty
                      ? 'Sign in to comment'
                      : 'Add a comment…',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(
                    alpha: .6,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(color: scheme.primary, width: 1.4),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedScale(
              duration: const Duration(milliseconds: 160),
              scale: canSend || _sending ? 1 : .9,
              child: IconButton.filled(
                tooltip: 'Post comment',
                onPressed: canSend ? _send : null,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The name a comment's author goes by: their display name, else their
/// @handle — never their account id.
String commentAuthorName(SocialPost c) => c.authorName.isNotEmpty
    ? c.authorName
    : c.authorHandle.isNotEmpty
    ? '@${c.authorHandle}'
    : 'Member';

/// Up to two initials of [name] ("Ada Lovelace" → "AL", "@ada" → "A").
String initialsOf(String name) {
  final words = name
      .replaceAll(RegExp(r'[@_.\-]+'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  return words.take(2).map((w) => w.characters.first.toUpperCase()).join();
}

String _timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${d.inDays ~/ 7}w';
}

/// One comment: its author's picture, a soft bubble with their name, the
/// time and the text, and a row of actions beneath it.
class _CommentTile extends StatelessWidget {
  const _CommentTile({
    super.key,
    required this.comment,
    required this.mine,
    required this.byPostAuthor,
    required this.busy,
    required this.headers,
    this.resolveUrl,
    required this.onLike,
    required this.onReply,
    required this.onCopy,
    required this.onDelete,
    required this.onReport,
  });
  final SocialPost comment;
  final bool mine;
  final bool byPostAuthor;
  final bool busy;
  final Map<String, String> headers;
  final String Function(String url)? resolveUrl;
  final VoidCallback onLike;
  final VoidCallback onReply;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = commentAuthorName(comment);
    void openAuthor() =>
        PostLinks.open(context, comment.authorId, comment.authorHandle);
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: busy ? .55 : 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: openAuthor,
              customBorder: const CircleBorder(),
              child: AppAvatar(
                initialsOf(name),
                color: feedColorFor(comment.authorId),
                radius: 17,
                avatar: comment.authorAvatar,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onLongPress: onCopy,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(14, 9, 14, 11),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(
                          alpha: .55,
                        ),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(6),
                          topRight: Radius.circular(18),
                          bottomLeft: Radius.circular(18),
                          bottomRight: Radius.circular(18),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: InkWell(
                                  onTap: openAuthor,
                                  borderRadius: BorderRadius.circular(6),
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                              if (byPostAuthor) ...[
                                const SizedBox(width: 6),
                                _Badge('Author', scheme.primary),
                              ] else if (mine) ...[
                                const SizedBox(width: 6),
                                _Badge('You', scheme.tertiary),
                              ],
                              const SizedBox(width: 6),
                              Text(
                                '· ${_timeAgo(comment.createdAt)}',
                                style: muted,
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          DefaultTextStyle.merge(
                            style: const TextStyle(fontSize: 14, height: 1.4),
                            child: RichPostContent(
                              comment.body,
                              headers: headers,
                              resolveUrl: resolveUrl,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _TextAction(
                        icon: comment.likedByMe
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        label: comment.likes > 0 ? '${comment.likes}' : 'Like',
                        tooltip: comment.likedByMe ? 'Unlike' : 'Like',
                        color: comment.likedByMe ? Colors.pinkAccent : null,
                        onTap: onLike,
                      ),
                      _TextAction(
                        icon: Icons.reply_rounded,
                        label: 'Reply',
                        tooltip: 'Reply',
                        onTap: onReply,
                      ),
                      const Spacer(),
                      _menu(scheme),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _menu(ColorScheme scheme) => AppPopupMenuButton<String>(
    tooltip: 'Comment options',
    enabled: !busy,
    iconSize: 18,
    icon: Icon(Icons.more_horiz_rounded, color: scheme.onSurfaceVariant),
    onSelected: (v) => switch (v) {
      'copy' => onCopy(),
      'delete' => onDelete(),
      'report' => onReport(),
      _ => null,
    },
    itemBuilder: (_) => [
      const PopupMenuItem(
        value: 'copy',
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.copy_rounded),
          title: Text('Copy text'),
        ),
      ),
      PopupMenuItem(
        value: mine ? 'delete' : 'report',
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            mine ? Icons.delete_outline_rounded : Icons.flag_outlined,
            color: scheme.error,
          ),
          title: Text(
            mine ? 'Delete comment' : 'Report comment',
            style: TextStyle(color: scheme.error),
          ),
        ),
      ),
    ],
  );
}

/// A small action under a comment: an icon and a word.
class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.color,
  });
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(99),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, a) =>
                    ScaleTransition(scale: a, child: child),
                child: Icon(icon, key: ValueKey(icon), size: 16, color: tint),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: tint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        color: color,
      ),
    ),
  );
}

/// A placeholder comment shown while the comments load.
class _CommentSkeleton extends StatelessWidget {
  const _CommentSkeleton({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withValues(alpha: .6);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(8),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 17, backgroundColor: tone),
          const SizedBox(width: 10),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(box.maxWidth * .35, 12),
                  const SizedBox(height: 8),
                  bar(box.maxWidth * (wide ? .9 : .65), 12),
                  const SizedBox(height: 6),
                  bar(box.maxWidth * (wide ? .55 : .4), 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: .6),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}
