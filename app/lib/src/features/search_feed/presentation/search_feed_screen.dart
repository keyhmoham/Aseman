import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_shape.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/glow_painter.dart';
import '../../../shared/widgets/notifications_menu.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/profile_menu.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/workspace_header.dart';
import '../../../shared/widgets/workspace_panel_motion.dart';
import '../../admin/presentation/admin_screen.dart';
import '../../assistant/assistant.dart';
import '../../home/presentation/workspace_screen.dart' show showExplore;
import '../../messenger/presentation/chat_page.dart';
import '../../messenger/presentation/messenger_panel.dart';
import '../domain/feed_post.dart';
import 'feed_post_card.dart';
import 'post_editor.dart';
import 'rich_post_parser.dart' show markupPreview;
import 'search_feed_view_model.dart';

/// Landing page: a Google-like search engine fused with the Following feed
/// (the posts of the people and agents the user follows mixed with the posts
/// of their spaces). The robot head + search bar live in a collapsible header.
/// Beside the feed, like the workspace's panels, the user's spaces sit on the
/// left and their direct chats on the right; on phones, Spaces and Chats
/// buttons flank the robot and open those sheets. The workspace-switch rocket
/// is not shown here.
class SearchFeedScreen extends StatefulWidget {
  const SearchFeedScreen({
    super.key,
    required this.dependencies,
    this.workspace = 'Home',
    this.onOpenWorkspace,
  });

  final AppDependencies dependencies;
  final String workspace;
  final ValueChanged<String>? onOpenWorkspace;

  @override
  State<SearchFeedScreen> createState() => _SearchFeedScreenState();
}

class _SearchFeedScreenState extends State<SearchFeedScreen>
    with TickerProviderStateMixin {
  late final SearchFeedViewModel model;

  /// The panels' motion, the same as a workspace switch: the feed arrives
  /// like a switched-to workspace and leaves like one.
  late final AnimationController motion =
      workspaceMotionController(this, value: 0);
  final scrollController = ScrollController();
  Timer? _chatsPoll;

  /// How many notifications are unread, badging the app bar's bell.
  int _unreadNotifications = 0;

  @override
  void initState() {
    super.initState();
    model = SearchFeedViewModel(
      dependencies: widget.dependencies,
      workspace: widget.workspace,
    );
    scrollController.addListener(_onScroll);
    model.load();
    // New messages arrive on their own time, like in the messenger.
    _chatsPoll = Timer.periodic(const Duration(seconds: 10), (_) {
      model.loadChats();
      _loadUnread();
    });
    _loadUnread();
    motion.forward();
  }

  Future<void> _loadUnread() async {
    try {
      final page = await widget.dependencies.service.fetchNotifications(limit: 1);
      if (mounted && page.unread != _unreadNotifications) {
        setState(() => _unreadNotifications = page.unread);
      }
    } catch (_) {}
  }

  Future<void> _openNotifications() async {
    setState(() => _unreadNotifications = 0);
    await showNotificationsMenu(context, widget.dependencies,
        onOpenSpace: widget.onOpenWorkspace == null ? null : _enterWorkspace);
    if (mounted) unawaited(_loadUnread());
  }

  /// Opens the workspace called [name] once the feed's panels have left.
  Future<void> _enterWorkspace(String name) async {
    final open = widget.onOpenWorkspace;
    if (open == null || motion.isAnimating) return;
    await motion.reverse();
    if (mounted) open(name);
  }

  bool get _compact => MediaQuery.sizeOf(context).width < 820;

  void _onScroll() {
    if (!scrollController.hasClients) return;
    if (scrollController.position.extentAfter < 300) {
      unawaited(model.loadMore());
    }
  }

  @override
  void didUpdateWidget(covariant SearchFeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) {
      model.setWorkspace(widget.workspace);
    }
  }

  @override
  void dispose() {
    _chatsPoll?.cancel();
    scrollController.dispose();
    motion.dispose();
    model.dispose();
    super.dispose();
  }

  Future<void> _openChat(ChatSummary chat) async {
    await showChat(context, widget.dependencies, chat);
    if (mounted) unawaited(model.loadChats());
  }

  Future<void> _openMessenger() async {
    await showMessenger(context, widget.dependencies);
    if (mounted) unawaited(model.loadChats());
  }

  /// The phone Spaces button opens the same workspace switch sheet the desk's
  /// rocket opens.
  void _openWorkspaceSwitcher() {
    final picker = WorkspacePicker(
        current: model.workspace,
        dependencies: widget.dependencies,
        feedSelected: true,
        onOpenFeed: () => Navigator.pop(context),
        onPick: (value) async {
          Navigator.pop(context);
          await Future<void>.delayed(const Duration(milliseconds: 320));
          if (mounted) await _enterWorkspace(value);
        });
    showAppSheet<void>(context, picker, heightFactor: .82);
  }

  /// The search bar opens Explore: the server's search across people,
  /// spaces, Following posts, direct chats and the market.
  Future<void> _openExplore([String query = '']) => showExplore(
      context, widget.dependencies,
      query: query,
      onOpenSpace: widget.onOpenWorkspace == null ? null : _enterWorkspace);

  Future<void> _openComposer() async {
    final body = await showPostEditor(
      context,
      hint: 'Share your analysis…',
    );
    if (body == null || body.trim().isEmpty) return;
    final id = await model.publish(body.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(id != null ? 'Post published' : 'Failed to publish'),
      ),
    );
  }

  void _toggleLike(FeedPost post) {
    final id = post.serverId;
    if (id == null) return;
    model.toggleLike(id, post.liked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = _compact;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
            child: CustomPaint(
                painter: GlowPainter(scheme.primary, scheme.tertiary))),
        SafeArea(
            child: AnimatedBuilder(
                animation: model,
                builder: (context, _) => Column(children: [
                      SizedBox(
                          height: 68,
                          child: _workspaceBar(context, compact)),
                      Expanded(child: LayoutBuilder(builder: (context, box) {
                        if (compact) {
                          return WorkspacePanelMotion(
                              animation: motion,
                              hiddenOffset: WorkspacePanelMotions.mobileOffset,
                              scaleFrom: WorkspacePanelMotions.mobileScale,
                              child: _feedScroll(compact: true));
                        }
                        // Placed and sized like the workspace's side panels.
                        return Padding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                            child: Row(children: [
                              WorkspacePanelMotion(
                                  animation: motion,
                                  hiddenOffset: WorkspacePanelMotions.left,
                                  child: SizedBox(
                                  width: math.min(286, box.maxWidth * .22),
                                  height: box.maxHeight * .82,
                                  child: _SidePanel(
                                      title: 'Spaces',
                                      icon: Icons.workspaces_outline,
                                      child: _SpacesList(
                                          spaces: model.spaces,
                                          current: model.workspace,
                                          loading: model.loading &&
                                              model.spaces.isEmpty,
                                          onOpen: _openSpace)))),
                              const SizedBox(width: 16),
                              Expanded(
                                  child: WorkspacePanelMotion(
                                      animation: motion,
                                      scaleFrom:
                                          WorkspacePanelMotions.centerScale,
                                      child: _feedScroll(compact: false))),
                              const SizedBox(width: 16),
                              WorkspacePanelMotion(
                                  animation: motion,
                                  hiddenOffset: WorkspacePanelMotions.right,
                                  child: SizedBox(
                                  width: math.min(330, box.maxWidth * .25),
                                  height: box.maxHeight * .88,
                                  child: _SidePanel(
                                      title: 'Chats',
                                      icon: Icons.forum_outlined,
                                      action: IconButton(
                                          tooltip: 'All messages',
                                          onPressed: _openMessenger,
                                          icon: const Icon(
                                              Icons.edit_square,
                                              size: 19)),
                                      child: _ChatsList(
                                          chats: model.chats,
                                          me: _me,
                                          loading: model.chatsLoading,
                                          onOpen: _openChat)))),
                            ]));
                      })),
                    ]))),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'feed-composer',
        onPressed: _openComposer,
        icon: const Icon(Icons.edit_rounded, size: 18),
        label: const Text('Post'),
      ),
    );
  }

  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';

  void _openSpace(Workspace space) => _enterWorkspace(space.name);

  /// The search hero over the feed; on phones Spaces and Chats flank the
  /// robot and open their sheets instead of swapping the scroll body.
  Widget _feedScroll({required bool compact}) =>
      LayoutBuilder(builder: (context, box) {
        final horizontalPad = math.max(16.0, (box.maxWidth - 760) / 2);
        return CustomScrollView(controller: scrollController, slivers: [
          SliverPersistentHeader(
              pinned: false,
              delegate: _SearchHeroDelegate(
                  compact: compact,
                  model: model,
                  onSearch: _openExplore,
                  onOpenSpaces: compact ? _openWorkspaceSwitcher : null,
                  onOpenChats: compact ? _openMessenger : null)),
          ..._feedSlivers(horizontalPad),
        ]);
      });

  Widget _workspaceBar(BuildContext context, bool compact) =>
      // Rebuilt when the account's avatar changes.
      ListenableBuilder(
          listenable: widget.dependencies.sessionController,
          builder: (context, _) => WorkspaceHeader(
              compact: compact,
              feed: true,
              onOpenNotifications: _openNotifications,
              unreadNotifications: _unreadNotifications,
              handle:
                  widget.dependencies.sessionController.session?.handle ?? '',
              avatar: widget.dependencies.service
                  .avatarImage(widget.dependencies.sessionController.avatar),
              onOpenAdmin: !widget.dependencies.sessionController.isAdmin
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              AdminScreen(dependencies: widget.dependencies),
                        ),
                      ),
              onOpenProfile: () =>
                  showProfileMenu(context, widget.dependencies)));

  List<Widget> _feedSlivers(double horizontalPad) {
    final posts = model.followingPosts;
    return [
      // The person's assistant leads their home: the brief, what waits on
      // them and what their agents suggest.
      SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontalPad, 4, horizontalPad, 0),
          sliver: SliverToBoxAdapter(
              child: HomeAssistant(
                  key: const ValueKey('home-assistant'),
                  dependencies: widget.dependencies))),
      SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 12),
          sliver: SliverToBoxAdapter(
              child: _FeedHeader(count: posts.length))),
      if (posts.isEmpty)
        const SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyFeed(
                message:
                    'Nothing here yet — follow people or join spaces to fill your feed.'))
      else
        SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, 32),
            sliver: SliverList.builder(
                itemCount: posts.length,
                itemBuilder: (context, index) {
                  final post = posts[index];
                  final id = post.serverId ?? '';
                  return FeedPostCard(
                      key: ValueKey('feed-post-$id'),
                      post: post,
                      dependencies: widget.dependencies,
                      onToggleLike: () => _toggleLike(post),
                      onEdited: (body) => model.edited(id, body),
                      onDeleted: () => model.deleted(id),
                      onShared: model.load);
                })),
      if (model.loadingMore)
        const SliverToBoxAdapter(child: SkeletonPost()),
    ];
  }
}

class _SearchHeroDelegate extends SliverPersistentHeaderDelegate {
  _SearchHeroDelegate({
    required this.compact,
    required this.model,
    required this.onSearch,
    this.onOpenSpaces,
    this.onOpenChats,
  });

  final bool compact;
  final SearchFeedViewModel model;
  final ValueChanged<String> onSearch;
  final VoidCallback? onOpenSpaces;
  final VoidCallback? onOpenChats;

  @override
  double get minExtent => 0;
  // Ends just under the suggestion chips so the assistant bar sits close.
  @override
  double get maxExtent => _HeroContent.extent(compact);
  @override
  bool shouldRebuild(covariant _SearchHeroDelegate old) =>
      old.compact != compact ||
      old.model != model ||
      old.onSearch != onSearch ||
      old.onOpenSpaces != onOpenSpaces ||
      old.onOpenChats != onOpenChats;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final progress = (shrinkOffset / maxExtent).clamp(0.0, 1.0);
    return _HeroContent(
        progress: progress,
        compact: compact,
        onSearch: onSearch,
        onOpenSpaces: onOpenSpaces,
        onOpenChats: onOpenChats);
  }
}

class _HeroContent extends StatelessWidget {
  const _HeroContent({
    required this.progress,
    required this.compact,
    required this.onSearch,
    this.onOpenSpaces,
    this.onOpenChats,
  });

  final double progress;
  final bool compact;
  final ValueChanged<String> onSearch;
  final VoidCallback? onOpenSpaces;
  final VoidCallback? onOpenChats;

  static double robotSizeFor(bool compact) => compact ? 124.0 : 148.0;

  /// Height that fits the robot, search bar and chips with a small bottom pad.
  static double extent(bool compact) {
    final robotSize = robotSizeFor(compact);
    final searchTop = 18 + robotSize + 26;
    final chipsTop = searchTop + 62 + 12;
    const chipsHeight = 36.0;
    const bottomPad = 4.0;
    return chipsTop + chipsHeight + bottomPad;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final robotSize = robotSizeFor(compact);
    final fade = (1 - progress).clamp(0.0, 1.0);
    final robotScale = 1 - .45 * progress;
    final searchTop = 18 + robotSize + 26;
    final chipsTop = searchTop + 62 + 12;
    final showSideActions = compact && onOpenSpaces != null && onOpenChats != null;
    return Stack(clipBehavior: Clip.hardEdge, children: [
      Positioned.fill(
          child: IgnorePointer(
              child: Opacity(
                  opacity: fade,
                  child: CustomPaint(
                      painter: GlowPainter(scheme.primary, scheme.tertiary))))),
      Positioned(
          top: 18,
          left: 0,
          right: 0,
          child: Opacity(
              opacity: fade,
              child: Transform.scale(
                  scale: robotScale,
                  child: SizedBox(
                      height: robotSize,
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (showSideActions) ...[
                              _HeroSideButton(
                                  icon: Icons.workspaces_outline,
                                  title: 'Spaces',
                                  onTap: onOpenSpaces!),
                              const SizedBox(width: 4),
                            ],
                            _RobotHead(size: robotSize),
                            if (showSideActions) ...[
                              const SizedBox(width: 4),
                              _HeroSideButton(
                                  icon: Icons.forum_outlined,
                                  title: 'Chats',
                                  onTap: onOpenChats!),
                            ],
                          ]))))),
      Positioned(
          top: searchTop,
          left: 0,
          right: 0,
          child: Opacity(
              opacity: fade,
              child: Transform.translate(
                  offset: Offset(0, -progress * 12),
                  child: _BigSearchBar(
                      onTap: () => onSearch(''), compact: compact)))),
      Positioned(
          top: chipsTop,
          left: 0,
          right: 0,
          child: Opacity(
              opacity: fade,
              child: _SuggestionChips(onSuggestion: onSearch))),
    ]);
  }
}

/// Icon + title control flanking the robot on phones.
class _HeroSideButton extends StatelessWidget {
  const _HeroSideButton({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
        message: title,
        child: Semantics(
            button: true,
            label: title,
            child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                    width: 72,
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, size: 26, color: scheme.onSurface),
                          const SizedBox(height: 6),
                          Text(title,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurfaceVariant)),
                        ])))));
  }
}

class _RobotHead extends StatelessWidget {
  const _RobotHead({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
        child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
              BoxShadow(
                  color: scheme.primary.withValues(alpha: .3),
                  blurRadius: 56,
                  spreadRadius: 4),
              BoxShadow(
                  color: scheme.tertiary.withValues(alpha: .16),
                  blurRadius: 92,
                  spreadRadius: 16)
            ]),
            child: Image.asset('assets/images/only_orb.png',
                fit: BoxFit.contain)));
  }
}

class _BigSearchBar extends StatelessWidget {
  const _BigSearchBar({required this.onTap, required this.compact});

  /// Opens Explore, where the search is typed.
  final VoidCallback onTap;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
        child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 0),
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Container(
                    height: 62,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(31),
                        border: Border.all(
                            color: scheme.primary.withValues(alpha: .4)),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: .18),
                              blurRadius: 34,
                              offset: const Offset(0, 14))
                        ]),
                    child: Row(children: [
                      Icon(Icons.search_rounded,
                          color: scheme.primary, size: 26),
                      const SizedBox(width: 12),
                      Expanded(
                          child: TextField(
                              readOnly: true,
                              onTap: onTap,
                              mouseCursor: SystemMouseCursors.click,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w500),
                              decoration: InputDecoration(
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  hintText:
                                      'Search Aseman — signals, traders, agents…',
                                  hintStyle: TextStyle(
                                      fontSize: 15,
                                      color: scheme.onSurfaceVariant)))),
                      IconButton.filled(
                          tooltip: 'Explore',
                          onPressed: onTap,
                          icon: const Icon(Icons.arrow_upward_rounded)),
                    ])))));
  }
}

class _SuggestionChips extends StatelessWidget {
  const _SuggestionChips({required this.onSuggestion});
  final ValueChanged<String> onSuggestion;
  static const suggestions = ['About Aseman', 'Best agents'];
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Same surface as the tasks pulse card under the hero.
    final chipColor = scheme.surfaceContainerHigh.withValues(alpha: .78);
    return LayoutBuilder(builder: (context, box) {
      final chips = [
        for (final s in suggestions) ...[
          if (s != suggestions.first) const SizedBox(width: 8),
          ActionChip(
              avatar: Icon(Icons.help_outline_rounded,
                  size: 14, color: scheme.onSurfaceVariant),
              label: Text(s),
              visualDensity: VisualDensity.compact,
              backgroundColor: chipColor,
              side: BorderSide.none,
              onPressed: () => onSuggestion(s)),
        ],
      ];
      // One horizontal row: centered when it fits, scrollable when it does not.
      return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: box.maxWidth - 24),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: chips)));
    });
  }
}

class _FeedHeader extends StatelessWidget {
  const _FeedHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const title = 'Following';
    const subtitle = 'People and agents you follow, and your spaces';
    return Row(children: [
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(title,
            style: TextStyle(
                fontSize: 22, letterSpacing: -.3, fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(subtitle,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))
      ])),
      const SizedBox(width: 12),
      Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(999)),
          child: Text('$count ${count == 1 ? 'post' : 'posts'}',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSecondaryContainer))),
    ]);
  }
}


class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({this.message});
  final String? message;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 72,
        height: 72,
        decoration: ShapeDecoration(
            color: scheme.secondaryContainer,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24))),
        child: Icon(Icons.search_off_rounded,
            size: 34, color: scheme.onSecondaryContainer),
      ),
      const SizedBox(height: 14),
      Text(message ?? 'No matching results',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text('Try a different search or tab',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))
    ]));
  }
}

/// A side panel of the feed, styled like the workspace's side panels.
class _SidePanel extends StatelessWidget {
  const _SidePanel(
      {required this.title,
      required this.icon,
      required this.child,
      this.action});
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: .92),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .6)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: .12),
                  blurRadius: 30,
                  offset: const Offset(0, 12))
            ]),
        child: Material(
            type: MaterialType.transparency,
            child: Column(children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
                  child: SizedBox(
                      height: 40,
                      child: Row(children: [
                        Icon(icon, size: 19, color: scheme.primary),
                        const SizedBox(width: 9),
                        Expanded(
                            child: Text(title,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800))),
                        if (action != null) action!,
                      ]))),
              Expanded(child: child),
            ])));
  }
}

/// A short centered note in an empty or loading panel list.
class _PanelNote extends StatelessWidget {
  const _PanelNote({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 30, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ]));
  }
}

/// The spaces the user is a member of; tapping one opens it.
class _SpacesList extends StatelessWidget {
  const _SpacesList({
    required this.spaces,
    required this.current,
    required this.loading,
    required this.onOpen,
  });
  final List<Workspace> spaces;
  final String current;
  final bool loading;
  final ValueChanged<Workspace> onOpen;

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonList(itemCount: 4);
    if (spaces.isEmpty) {
      return const _PanelNote(
          icon: Icons.workspaces_outline,
          text: 'You are not a member of any space yet.');
    }
    return ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        itemCount: spaces.length,
        itemBuilder: (context, i) => _SpaceTile(
            space: spaces[i],
            selected: spaces[i].name == current,
            dense: true,
            onTap: () => onOpen(spaces[i])));
  }
}

class _SpaceTile extends StatelessWidget {
  const _SpaceTile(
      {required this.space,
      required this.selected,
      required this.onTap,
      this.dense = false});
  final Workspace space;
  final bool selected;
  final VoidCallback onTap;

  /// Narrower desktop side-panel rows.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final role = space.role.isEmpty
        ? ''
        : '${space.role[0].toUpperCase()}${space.role.substring(1)}';
    final details = [
      if (space.home) 'Home',
      if (role.isNotEmpty) role,
      space.public ? 'Public' : 'Private',
    ].join(' · ');
    final avatarSize = dense ? 36.0 : 52.0;
    final avatarRadius = dense ? 12.0 : 16.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: .45)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShape.inner)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: dense ? 10 : 12, vertical: dense ? 8 : 12),
            child: Row(children: [
              AvatarPicture(
                avatar: space.avatar,
                size: avatarSize,
                radius: avatarRadius,
                fallback: Container(
                  width: avatarSize,
                  height: avatarSize,
                  alignment: Alignment.center,
                  decoration: ShapeDecoration(
                      color: scheme.secondaryContainer,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(avatarRadius))),
                  child: Text(space.initials,
                      style: TextStyle(
                          fontSize: dense ? 13 : 18,
                          fontWeight: FontWeight.w800,
                          color: scheme.onSecondaryContainer)),
                ),
              ),
              SizedBox(width: dense ? 10 : 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(space.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: dense ? 13.5 : 16,
                              fontWeight: FontWeight.w700)),
                      SizedBox(height: dense ? 2 : 3),
                      Text(details,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: dense ? 11.5 : 13.5,
                              color: scheme.onSurfaceVariant)),
                    ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The user's direct chats; tapping one opens the chat.
class _ChatsList extends StatelessWidget {
  const _ChatsList({
    required this.chats,
    required this.me,
    required this.loading,
    required this.onOpen,
  });
  final List<ChatSummary> chats;
  final String me;
  final bool loading;
  final ValueChanged<ChatSummary> onOpen;

  @override
  Widget build(BuildContext context) {
    if (loading && chats.isEmpty) return const SkeletonList(itemCount: 4);
    if (chats.isEmpty) {
      return const _PanelNote(
          icon: Icons.forum_outlined, text: 'No direct chats yet.');
    }
    return ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        itemCount: chats.length,
        itemBuilder: (context, i) => _DirectChatTile(
            chat: chats[i],
            me: me,
            dense: true,
            onTap: () => onOpen(chats[i])));
  }
}

class _DirectChatTile extends StatelessWidget {
  const _DirectChatTile(
      {required this.chat,
      required this.me,
      required this.onTap,
      this.dense = false});
  final ChatSummary chat;
  final String me;
  final VoidCallback onTap;

  /// Narrower desktop side-panel rows.
  final bool dense;

  String get _preview {
    if (chat.working) return 'Agent is working…';
    if (chat.typing) return 'typing…';
    final body = markupPreview(chat.lastBody);
    final text = body.isNotEmpty
        ? body
        : chat.lastAttachments > 0
            ? '📎 Attachment'
            : chat.saved
                ? 'Notes, links and files for yourself'
                : 'Say hello';
    return body.isNotEmpty && chat.lastSenderId == me ? 'You: $text' : text;
  }

  static String _when(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = chat.unread > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: unread
            ? scheme.primaryContainer.withValues(alpha: .35)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShape.inner)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: dense ? 10 : 12, vertical: dense ? 8 : 12),
            child: Row(children: [
              ChatAvatar(chat: chat, radius: dense ? 18 : 26),
              SizedBox(width: dense ? 10 : 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: dense ? 13.5 : 16,
                              fontWeight:
                                  unread ? FontWeight.w800 : FontWeight.w700)),
                      SizedBox(height: dense ? 2 : 3),
                      Text(_preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: dense ? 11.5 : 13.5,
                              color: chat.working || chat.typing
                                  ? scheme.primary
                                  : unread
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant)),
                    ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_when(chat.updatedAt),
                    style: TextStyle(
                        fontSize: dense ? 11 : 12,
                        color:
                            unread ? scheme.primary : scheme.onSurfaceVariant)),
                SizedBox(height: dense ? 4 : 6),
                if (unread)
                  Badge(
                      label:
                          Text(chat.unread > 99 ? '99+' : '${chat.unread}'),
                      backgroundColor: scheme.primary,
                      textColor: scheme.onPrimary)
                else
                  SizedBox(height: dense ? 14 : 18),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
