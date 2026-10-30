import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../shared/widgets/glow_painter.dart';
import '../../../shared/widgets/notifications_menu.dart';
import '../../../shared/widgets/profile_menu.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/workspace_header.dart';
import '../../../shared/widgets/workspace_panel_motion.dart';
import '../../admin/presentation/admin_screen.dart';
import '../../assistant/assistant.dart';
import '../../home/presentation/workspace_screen.dart' show showExplore;
import '../../messenger/presentation/messenger_panel.dart';
import '../domain/feed_post.dart';
import 'feed_post_card.dart';
import 'post_editor.dart';
import 'search_feed_view_model.dart';

/// Landing page: a Google-like search engine fused with the Following feed
/// (the posts of the people and agents the user follows mixed with the posts
/// of their spaces). A compact search bar sits in a collapsible header.
/// Beside the feed, the same Spaces (`WorkspacePicker`) and Chats
/// (`MessengerPanel`) used as mobile home tabs sit in side rails. On phones a
/// floating bottom bar switches full-page tabs — Chats (default), Spaces,
/// Explore. The workspace-switch rocket is not shown here.
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

/// Mobile home tabs under the floating bottom bar.
enum _MobileHomeTab { chats, spaces, explore }

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

  /// Phones land on Chats; Explore is the feed tab.
  _MobileHomeTab _mobileTab = _MobileHomeTab.chats;

  @override
  void initState() {
    super.initState();
    model = SearchFeedViewModel(
      dependencies: widget.dependencies,
      workspace: widget.workspace,
    );
    scrollController.addListener(_onScroll);
    model.load();
    // Bell badge; chats refresh themselves inside MessengerPanel.
    _chatsPoll = Timer.periodic(const Duration(seconds: 10), (_) {
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

  void _setMobileTab(_MobileHomeTab tab) {
    if (_mobileTab == tab) return;
    setState(() => _mobileTab = tab);
  }

  /// The search bar opens the search panel: people, spaces, Following posts,
  /// direct chats and the market.
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

  /// Clearance under the floating home bar so tab content is not covered.
  double _mobileNavClearance(BuildContext context) =>
      78 + MediaQuery.paddingOf(context).bottom;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = _compact;
    final showComposer =
        !compact || _mobileTab == _MobileHomeTab.explore;
    return Scaffold(
      extendBody: compact,
      body: Stack(children: [
        Positioned.fill(
            child: CustomPaint(
                painter: GlowPainter(scheme.primary, scheme.tertiary))),
        SafeArea(
            bottom: !compact,
            child: AnimatedBuilder(
                animation: model,
                builder: (context, _) => Column(children: [
                      SizedBox(
                          height: 68,
                          child: _workspaceBar(context, compact)),
                      Expanded(child: LayoutBuilder(builder: (context, box) {
                        if (compact) {
                          final clearance = _mobileNavClearance(context);
                          return Padding(
                              padding: EdgeInsets.only(bottom: clearance),
                              child: IndexedStack(
                                  index: _mobileTab.index,
                                  sizing: StackFit.expand,
                                  children: [
                                    MessengerPanel(
                                        dependencies: widget.dependencies,
                                        embedded: true),
                                    WorkspacePicker(
                                        current: model.workspace,
                                        dependencies: widget.dependencies,
                                        embedded: true,
                                        onPick: (value) =>
                                            unawaited(_enterWorkspace(value))),
                                    WorkspacePanelMotion(
                                        animation: motion,
                                        hiddenOffset:
                                            WorkspacePanelMotions.mobileOffset,
                                        scaleFrom:
                                            WorkspacePanelMotions.mobileScale,
                                        child: _feedScroll(compact: true)),
                                  ]));
                        }
                        // Same Spaces / Chats components as the mobile tabs.
                        final sideWidth =
                            math.min(380.0, box.maxWidth * .28);
                        return Padding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                            child: Row(children: [
                              WorkspacePanelMotion(
                                  animation: motion,
                                  hiddenOffset: WorkspacePanelMotions.left,
                                  child: _DesktopRail(
                                      width: sideWidth,
                                      height: box.maxHeight * .82,
                                      child: WorkspacePicker(
                                          current: model.workspace,
                                          dependencies: widget.dependencies,
                                          embedded: true,
                                          onPick: (value) => unawaited(
                                              _enterWorkspace(value))))),
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
                                  child: _DesktopRail(
                                      width: sideWidth,
                                      height: box.maxHeight * .88,
                                      child: MessengerPanel(
                                          dependencies: widget.dependencies,
                                          embedded: true))),
                            ]));
                      })),
                    ]))),
        if (compact)
          Positioned(
              left: 16,
              right: 16,
              bottom: 12 + MediaQuery.paddingOf(context).bottom,
              child: _FloatingHomeNav(
                  tab: _mobileTab, onSelect: _setMobileTab)),
      ]),
      floatingActionButton: !showComposer
          ? null
          : Padding(
              padding: EdgeInsets.only(
                  bottom: compact ? _mobileNavClearance(context) - 12 : 0),
              child: FloatingActionButton.extended(
                heroTag: 'feed-composer',
                onPressed: _openComposer,
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Post'),
              ),
            ),
    );
  }

  /// Compact search bar over the Explore feed.
  Widget _feedScroll({required bool compact}) =>
      LayoutBuilder(builder: (context, box) {
        final horizontalPad = math.max(16.0, (box.maxWidth - 760) / 2);
        return CustomScrollView(controller: scrollController, slivers: [
          SliverPersistentHeader(
              pinned: false,
              delegate: _SearchHeroDelegate(
                  compact: compact,
                  model: model,
                  onSearch: _openExplore)),
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
  });

  final bool compact;
  final SearchFeedViewModel model;
  final ValueChanged<String> onSearch;

  @override
  double get minExtent => 0;
  @override
  double get maxExtent => _HeroContent.extent(compact);
  @override
  bool shouldRebuild(covariant _SearchHeroDelegate old) =>
      old.compact != compact ||
      old.model != model ||
      old.onSearch != onSearch;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final progress = (shrinkOffset / maxExtent).clamp(0.0, 1.0);
    return _HeroContent(
        progress: progress, compact: compact, onSearch: onSearch);
  }
}

class _HeroContent extends StatelessWidget {
  const _HeroContent({
    required this.progress,
    required this.compact,
    required this.onSearch,
  });

  final double progress;
  final bool compact;
  final ValueChanged<String> onSearch;

  static const _barHeight = 44.0;

  /// Height that fits the compact search bar with a small bottom pad.
  static double extent(bool compact) => 12 + _barHeight + 8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fade = (1 - progress).clamp(0.0, 1.0);
    return Stack(clipBehavior: Clip.hardEdge, children: [
      Positioned.fill(
          child: IgnorePointer(
              child: Opacity(
                  opacity: fade,
                  child: CustomPaint(
                      painter: GlowPainter(scheme.primary, scheme.tertiary))))),
      Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Opacity(
              opacity: fade,
              child: Transform.translate(
                  offset: Offset(0, -progress * 8),
                  child: _SearchBar(
                      onTap: () => onSearch(''), compact: compact)))),
    ]);
  }
}

/// Floating pill nav for the mobile home: Chats, Spaces, Explore.
class _FloatingHomeNav extends StatelessWidget {
  const _FloatingHomeNav({required this.tab, required this.onSelect});

  final _MobileHomeTab tab;
  final ValueChanged<_MobileHomeTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
        elevation: 10,
        shadowColor: Colors.black54,
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: NavigationBar(
          height: 64,
          backgroundColor: Colors.transparent,
          indicatorColor: scheme.primaryContainer,
          selectedIndex: tab.index,
          onDestinationSelected: (i) => onSelect(_MobileHomeTab.values[i]),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.forum_outlined),
                selectedIcon: Icon(Icons.forum_rounded),
                label: 'Chats'),
            NavigationDestination(
                icon: Icon(Icons.workspaces_outline),
                selectedIcon: Icon(Icons.workspaces_rounded),
                label: 'Spaces'),
            NavigationDestination(
                icon: Icon(Icons.explore_outlined),
                selectedIcon: Icon(Icons.explore_rounded),
                label: 'Explore'),
          ],
        ));
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap, required this.compact});

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
                constraints: const BoxConstraints(maxWidth: 520),
                child: Material(
                    color: scheme.surface.withValues(alpha: .88),
                    elevation: 1,
                    shadowColor: Colors.black26,
                    shape: StadiumBorder(
                        side: BorderSide(
                            color: scheme.outlineVariant.withValues(alpha: .7))),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                        onTap: onTap,
                        child: SizedBox(
                            height: _HeroContent._barHeight,
                            child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 14),
                                child: Row(children: [
                                  Icon(Icons.search_rounded,
                                      color: scheme.onSurfaceVariant, size: 20),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(
                                          'Search Aseman…',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w400,
                                              color: scheme.onSurfaceVariant))),
                                ]))))))));
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

/// Chrome around the desktop Spaces / Chats rails (same components as the
/// mobile tabs; the components paint their own headers).
class _DesktopRail extends StatelessWidget {
  const _DesktopRail({
    required this.width,
    required this.height,
    required this.child,
  });

  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
        width: width,
        height: height,
        child: Container(
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
            child: Material(type: MaterialType.transparency, child: child)));
  }
}
