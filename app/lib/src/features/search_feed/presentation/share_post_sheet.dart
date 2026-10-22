import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_dependencies.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../messenger/presentation/chat_page.dart' show ChatAvatar;
import '../domain/feed_post.dart';
import 'post_actions.dart';
import 'rich_post_parser.dart';

/// Opens the share modal of [post]: the platform's share sheet, a copy of
/// its text, a repost to the user's public feed or the feed of a space they
/// are in, and a forward to any of their chats and project rooms. Shared
/// posts keep their original author. Returns how many places it was shared
/// to inside the app.
Future<int?> showSharePostSheet(
  BuildContext context,
  AppDependencies dependencies,
  FeedPost post,
) => showAdaptivePanel<int>(
  context,
  SharePostSheet(dependencies: dependencies, post: post),
  breakpoint: 720,
  maxWidth: 560,
  maxHeight: 760,
  heightFactor: .9,
);

class SharePostSheet extends StatefulWidget {
  const SharePostSheet({
    super.key,
    required this.dependencies,
    required this.post,
  });
  final AppDependencies dependencies;
  final FeedPost post;

  @override
  State<SharePostSheet> createState() => _SharePostSheetState();
}

class _SharePostSheetState extends State<SharePostSheet> {
  /// The public feed's key among the feed destinations.
  static const _publicFeed = '';

  List<Workspace> _spaces = const [];
  List<ChatSummary> _chats = const [];
  bool _loading = true;
  String? _loadError;
  final _feeds = <String>{};
  final _chatKeys = <String>{};
  final _query = TextEditingController();
  final _message = TextEditingController();
  bool _sending = false;

  FeedPost get post => widget.post;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = widget.dependencies.service;
    try {
      final results = await Future.wait([
        service.fetchSpaces(),
        service.fetchChats(),
      ]);
      if (!mounted) return;
      setState(() {
        // Direct chats are one-room spaces of their own; they are offered
        // as chats, not feeds.
        final directSpaces = {
          for (final c in results[1] as List<ChatSummary>)
            if (c.direct) c.spaceId,
        };
        _spaces = (results[0] as List<Workspace>)
            .where((s) => !directSpaces.contains(s.id))
            .toList();
        _chats = (results[1] as List<ChatSummary>)
            .where((c) => c.canSend)
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  int get _selected => _feeds.length + _chatKeys.length;

  String get _q => _query.text.trim().toLowerCase();

  List<Workspace> get _visibleSpaces => _spaces
      .where((s) => _q.isEmpty || s.name.toLowerCase().contains(_q))
      .toList();

  List<ChatSummary> get _visibleChats => _chats
      .where(
        (c) =>
            _q.isEmpty ||
            '${c.title} ${c.spaceName} ${c.peer?.handle ?? ''}'
                .toLowerCase()
                .contains(_q),
      )
      .toList();

  /// The original of the post: the post itself, or the one it shares.
  String get _originalId =>
      post.isForward ? post.forwardOf : (post.serverId ?? '');

  String _chatBody() {
    final directive = forwardedPostMarkup(
      id: _originalId,
      authorId: post.isForward ? post.forwardAuthorId : post.authorId,
      name: post.isForward ? post.forwardName : post.name,
      handle: post.isForward
          ? post.forwardHandle
          : post.handle.replaceFirst('@', ''),
      avatar: post.isForward ? post.forwardAvatar : post.avatar,
      body: post.body,
    );
    final note = _message.text.trim();
    return note.isEmpty ? directive : '$note\n\n$directive';
  }

  Future<void> _share() async {
    final id = post.serverId;
    if (id == null || _selected == 0 || _sending) return;
    setState(() => _sending = true);
    final service = widget.dependencies.service;
    Future<bool> attempt(Future<Object?> Function() run) async {
      try {
        await run();
        return true;
      } catch (_) {
        return false;
      }
    }

    final body = _chatBody();
    final results = await Future.wait([
      for (final feed in _feeds)
        attempt(
          () => service.forwardPost(
            id,
            spaceId: feed == _publicFeed ? null : feed,
          ),
        ),
      for (final c in _chats.where((c) => _chatKeys.contains(c.key)))
        attempt(() => service.sendRoomMessage(c.spaceId, c.roomId, body)),
    ]);
    if (!mounted) return;
    final done = results.where((ok) => ok).length;
    final failed = results.length - done;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (failed == 0) {
      Navigator.pop(context, done);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(done == 1 ? 'Shared' : 'Shared to $done places'),
        ),
      );
    } else {
      setState(() => _sending = false);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            done == 0
                ? 'Could not share the post'
                : 'Shared to $done; $failed failed',
          ),
        ),
      );
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: markupPlainText(post.body)));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Text copied')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chats = _visibleChats;
    final spaces = _visibleSpaces;
    final showPublic = _q.isEmpty || 'public feed'.contains(_q);
    return Material(
      color: Colors.transparent,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Share post',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  sliver: SliverList.list(
                    children: [
                      _PostPreview(post: post),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Builder(
                              builder: (context) => _QuickAction(
                                icon: Icons.ios_share_rounded,
                                label: 'Share via…',
                                onTap: () => sharePostExternally(context, post),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _QuickAction(
                              icon: Icons.copy_rounded,
                              label: 'Copy text',
                              onTap: _copy,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _query,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search_rounded),
                          hintText: 'Search spaces and chats',
                          suffixIcon: _query.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear',
                                  onPressed: () => setState(_query.clear),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const _SectionLabel('Repost to a feed'),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 96,
                    child: _loading && _spaces.isEmpty
                        ? const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            children: [
                              if (showPublic)
                                _FeedTarget(
                                  label: 'Public feed',
                                  selected: _feeds.contains(_publicFeed),
                                  onTap: () => setState(
                                    () => _toggle(_feeds, _publicFeed),
                                  ),
                                  child: CircleAvatar(
                                    radius: 26,
                                    backgroundColor: scheme.primaryContainer,
                                    child: Icon(
                                      Icons.public_rounded,
                                      color: scheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              for (final s in spaces)
                                _FeedTarget(
                                  label: s.name,
                                  selected: _feeds.contains(s.id),
                                  onTap: () =>
                                      setState(() => _toggle(_feeds, s.id)),
                                  child: AvatarPicture(
                                    avatar: s.avatar,
                                    size: 52,
                                    radius: 16,
                                    fallback: Container(
                                      width: 52,
                                      height: 52,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: scheme.secondaryContainer,
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Text(
                                        s.name.isEmpty
                                            ? '#'
                                            : s.name.characters.first
                                                  .toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                          color: scheme.onSecondaryContainer,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
                const SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                  sliver: SliverToBoxAdapter(
                    child: _SectionLabel('Send to a chat'),
                  ),
                ),
                if (_loadError != null && _chats.isEmpty)
                  const SliverToBoxAdapter(
                    child: _Note(
                      icon: Icons.cloud_off_rounded,
                      text: 'Your chats could not be loaded.',
                    ),
                  )
                else if (!_loading && chats.isEmpty)
                  SliverToBoxAdapter(
                    child: _Note(
                      icon: Icons.forum_outlined,
                      text: _q.isEmpty
                          ? 'No chats to send to yet.'
                          : 'No chat matches “${_query.text.trim()}”.',
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    sliver: SliverList.builder(
                      itemCount: chats.length,
                      itemBuilder: (context, i) {
                        final c = chats[i];
                        final on = _chatKeys.contains(c.key);
                        return _ChatTarget(
                          chat: c,
                          selected: on,
                          onTap: () =>
                              setState(() => _toggle(_chatKeys, c.key)),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          _bottomBar(scheme),
        ],
      ),
    );
  }

  Widget _bottomBar(ColorScheme scheme) => AnimatedSize(
    duration: const Duration(milliseconds: 180),
    alignment: Alignment.bottomCenter,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_chatKeys.isNotEmpty) ...[
            TextField(
              controller: _message,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
                hintText: 'Add a message (optional)',
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  _selected == 0
                      ? 'Pick feeds or chats to share to'
                      : [
                          if (_feeds.isNotEmpty)
                            '${_feeds.length} feed${_feeds.length == 1 ? '' : 's'}',
                          if (_chatKeys.isNotEmpty)
                            '${_chatKeys.length} chat${_chatKeys.length == 1 ? '' : 's'}',
                        ].join(' · '),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: _selected == 0 || _sending ? null : _share,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(_selected <= 1 ? 'Share' : 'Share to $_selected'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  static void _toggle(Set<String> set, String key) {
    if (!set.remove(key)) set.add(key);
  }
}

/// The post being shared, small: its author and the start of its text.
class _PostPreview extends StatelessWidget {
  const _PostPreview({required this.post});
  final FeedPost post;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = post.isForward ? post.forwardName : post.name;
    final text = markupPreview(post.body);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            post.initials,
            color: post.color,
            radius: 18,
            avatar: post.isForward ? post.forwardAvatar : post.avatar,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  text.isEmpty ? 'A post' : text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: scheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      letterSpacing: 1,
      fontWeight: FontWeight.w800,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// A feed to repost to: its picture with a check when picked, and its name.
class _FeedTarget extends StatelessWidget {
  const _FeedTarget({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 76,
          child: Column(
            children: [
              const SizedBox(height: 4),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(19),
                      border: Border.all(
                        width: 2,
                        color: selected ? scheme.primary : Colors.transparent,
                      ),
                    ),
                    child: child,
                  ),
                  if (selected)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: CircleAvatar(
                        radius: 10,
                        backgroundColor: scheme.primary,
                        child: Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A chat or room to send the post to, with a round check box.
class _ChatTarget extends StatelessWidget {
  const _ChatTarget({
    required this.chat,
    required this.selected,
    required this.onTap,
  });
  final ChatSummary chat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = chat.saved
        ? 'Just you'
        : chat.direct
        ? (chat.peer?.isAgent ?? false)
              ? 'Agent'
              : (chat.peer?.handle.isNotEmpty ?? false)
              ? '@${chat.peer!.handle}'
              : 'Direct chat'
        : 'Room · ${chat.spaceName}';
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: .35)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              ChatAvatar(chat: chat, radius: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? scheme.primary : Colors.transparent,
                  border: Border.all(
                    width: 2,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ),
                child: selected
                    ? Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: scheme.onPrimary,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
