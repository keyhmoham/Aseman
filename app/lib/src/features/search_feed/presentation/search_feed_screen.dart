import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../shared/widgets/glass_surface.dart';
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
import 'feed_canvas.dart';
import 'feed_post_card.dart';
import 'post_editor.dart';
import 'search_feed_view_model.dart';

/// Landing page. On a wide screen the chats sit in the left rail, the posts
/// (with today's brief and tasks) in the right rail, and the center is a free
/// desk for pinned windows from every space. On a phone a floating pill of
/// captioned tabs switches Chats, that desk, and the feed. The spaces grid
/// is not on this page; a space opens from the desk's toolbox.
/// Mobile home tabs under that pill.
enum HomeMobileTab { chats, desk, feed }

class SearchFeedScreen extends StatefulWidget {
  const SearchFeedScreen({
    super.key,
    required this.dependencies,
    this.workspace = 'Home',
    this.onOpenWorkspace,
    this.onOpenSpaceRoom,
    this.initialMobileTab = HomeMobileTab.chats,
  });

  final AppDependencies dependencies;
  final String workspace;
  final ValueChanged<String>? onOpenWorkspace;

  /// Opens [spaceName] on the workspace page with [roomName] / [roomId]
  /// already selected (desk, chat, and the rest of that room).
  final void Function(String spaceName, String roomName, String roomId)?
  onOpenSpaceRoom;

  /// Which phone tab to show on mount. Chats on first land and when the
  /// workspace Home button returns here.
  final HomeMobileTab initialMobileTab;

  @override
  State<SearchFeedScreen> createState() => _SearchFeedScreenState();
}

class _SearchFeedScreenState extends State<SearchFeedScreen>
    with TickerProviderStateMixin {
  late final SearchFeedViewModel model;
  late final FeedCanvasController canvas;

  /// The panels' motion, the same as a workspace switch: the feed arrives
  /// like a switched-to workspace and leaves like one.
  late final AnimationController motion = workspaceMotionController(
    this,
    value: 0,
  );
  final scrollController = ScrollController();
  Timer? _chatsPoll;

  /// How many notifications are unread, badging the app bar's bell.
  int _unreadNotifications = 0;

  late HomeMobileTab _mobileTab;

  @override
  void initState() {
    super.initState();
    _mobileTab = widget.initialMobileTab;
    model = SearchFeedViewModel(
      dependencies: widget.dependencies,
      workspace: widget.workspace,
    );
    canvas = FeedCanvasController(dependencies: widget.dependencies);
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
      final page = await widget.dependencies.service.fetchNotifications(
        limit: 1,
      );
      if (mounted && page.unread != _unreadNotifications) {
        setState(() => _unreadNotifications = page.unread);
      }
    } catch (_) {}
  }

  Future<void> _openNotifications() async {
    setState(() => _unreadNotifications = 0);
    await showNotificationsMenu(
      context,
      widget.dependencies,
      onOpenSpace: widget.onOpenWorkspace == null ? null : _enterWorkspace,
    );
    if (mounted) unawaited(_loadUnread());
  }

  /// Opens the workspace called [name] once the feed's panels have left.
  Future<void> _enterWorkspace(String name) async {
    final open = widget.onOpenWorkspace;
    if (open == null || motion.isAnimating) return;
    await motion.reverse();
    if (mounted) open(name);
  }

  /// Opens [name] with [roomName] selected, once the feed's panels have left.
  Future<void> _enterWorkspaceRoom(
    String name,
    String roomName,
    String roomId,
  ) async {
    final open = widget.onOpenSpaceRoom;
    if (open == null || motion.isAnimating) return;
    await motion.reverse();
    if (mounted) open(name, roomName, roomId);
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
    canvas.dispose();
    super.dispose();
  }

  void _setMobileTab(HomeMobileTab tab) {
    if (_mobileTab == tab) return;
    setState(() => _mobileTab = tab);
  }

  /// The search bar opens the search panel: people, spaces, Following posts,
  /// direct chats and the market.
  Future<void> _openExplore([String query = '']) => showExplore(
    context,
    widget.dependencies,
    query: query,
    onOpenSpace: widget.onOpenWorkspace == null ? null : _enterWorkspace,
  );

  Future<void> _openComposer() async {
    final body = await showPostEditor(context, hint: 'Share your analysis…');
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

  /// Lift the Post button above the home tab pill. The pill overlays tab
  /// content and does not reserve layout space; the scaffold already insets
  /// the button by 16.
  double _fabNavLift(BuildContext context) {
    const margin = 16.0;
    const gap = 12.0;
    return (HomeTabBar.occupied(context) + gap - margin).clamp(
      0.0,
      double.infinity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = _compact;
    final showComposer = !compact || _mobileTab == HomeMobileTab.feed;
    final appBarInset = FloatingAppBarLayout.contentInset(compact);
    return Scaffold(
      extendBody: compact,
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: GlowPainter(scheme.primary, scheme.tertiary),
            ),
          ),
          // Page content fills the safe area; each tab/rail reserves
          // [appBarInset] inside itself so scroll can pass under the bar.
          SafeArea(
            bottom: !compact,
            child: AnimatedBuilder(
              animation: model,
              builder: (context, _) => LayoutBuilder(
                builder: (context, box) {
                  if (compact) {
                    // The tab pill overlays these tabs. Glass fills the
                    // tab so content is not see-through against the page
                    // glow (desktop rails supply their own GlassSurface).
                    Widget glassTab(Widget child) => GlassSurface(
                      alpha: AppSurfaces.cardAlpha,
                      blur: AppSurfaces.blurSigma,
                      borderRadius: BorderRadius.zero,
                      border: false,
                      child: Padding(
                        padding: EdgeInsets.only(top: appBarInset),
                        child: child,
                      ),
                    );
                    final navLift = HomeTabBar.occupied(context);
                    return IndexedStack(
                      index: _mobileTab.index,
                      sizing: StackFit.expand,
                      children: [
                        glassTab(
                          MessengerPanel(
                            dependencies: widget.dependencies,
                            embedded: true,
                            onOpenSpaceRoom: widget.onOpenSpaceRoom == null
                                ? null
                                : _enterWorkspaceRoom,
                          ),
                        ),
                        glassTab(_desk(mobile: true, bottomInset: navLift)),
                        WorkspacePanelMotion(
                          animation: motion,
                          hiddenOffset: WorkspacePanelMotions.mobileOffset,
                          scaleFrom: WorkspacePanelMotions.mobileScale,
                          child: _feedScroll(
                            compact: true,
                            topInset: appBarInset,
                          ),
                        ),
                      ],
                    );
                  }
                  // Chats on the left, the free desk in the center, the
                  // posts (brief and tasks included) on the right. The two
                  // rails share one width.
                  final railWidth = math.min(320.0, box.maxWidth * .24);
                  final railHeight = math.max(0.0, box.maxHeight - appBarInset);
                  Widget denseRail(Widget child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: const TextScaler.linear(.88)),
                    child: child,
                  );
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                    child: Row(
                      children: [
                        WorkspacePanelMotion(
                          animation: motion,
                          hiddenOffset: WorkspacePanelMotions.left,
                          child: Padding(
                            padding: EdgeInsets.only(top: appBarInset),
                            child: _DesktopRail(
                              width: railWidth,
                              height: railHeight,
                              child: denseRail(
                                MessengerPanel(
                                  dependencies: widget.dependencies,
                                  embedded: true,
                                  dense: true,
                                  onOpenSpaceRoom:
                                      widget.onOpenSpaceRoom == null
                                      ? null
                                      : _enterWorkspaceRoom,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: WorkspacePanelMotion(
                            animation: motion,
                            scaleFrom: WorkspacePanelMotions.centerScale,
                            child: Padding(
                              padding: EdgeInsets.only(top: appBarInset),
                              child: _desk(mobile: false, bottomInset: 0),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        WorkspacePanelMotion(
                          animation: motion,
                          hiddenOffset: WorkspacePanelMotions.right,
                          child: Padding(
                            padding: EdgeInsets.only(top: appBarInset),
                            child: _DesktopRail(
                              width: railWidth,
                              height: railHeight,
                              child: _feedScroll(compact: true, topInset: 0),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          // Floating glass app bar over every home tab / desktop rails.
          SafeArea(bottom: false, child: _workspaceBar(context, compact)),
          if (compact)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: HomeTabBar(tab: _mobileTab, onSelect: _setMobileTab),
            ),
        ],
      ),
      floatingActionButton: !showComposer
          ? null
          : Padding(
              padding: EdgeInsets.only(
                bottom: compact ? _fabNavLift(context) : 0,
              ),
              child: FloatingActionButton.extended(
                heroTag: 'feed-composer',
                onPressed: _openComposer,
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Post'),
              ),
            ),
    );
  }

  Widget _desk({required bool mobile, required double bottomInset}) =>
      FeedCanvas(
        controller: canvas,
        dependencies: widget.dependencies,
        mobile: mobile,
        bottomInset: bottomInset,
        onOpenSpace: (name) => unawaited(_enterWorkspace(name)),
      );

  /// Compact search bar over the posts. [topInset] is reserved
  /// inside the scroll so the first paint clears the floating app bar and
  /// later scroll passes under it.
  Widget _feedScroll({required bool compact, required double topInset}) =>
      LayoutBuilder(
        builder: (context, box) {
          final horizontalPad = math.max(16.0, (box.maxWidth - 760) / 2);
          return CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: topInset)),
              SliverPersistentHeader(
                pinned: false,
                delegate: _SearchHeroDelegate(
                  compact: compact,
                  model: model,
                  onSearch: _openExplore,
                ),
              ),
              ..._feedSlivers(
                horizontalPad,
                bottom: compact ? 16 + HomeTabBar.occupied(context) : 32,
              ),
            ],
          );
        },
      );

  Widget _workspaceBar(BuildContext context, bool compact) =>
      // Rebuilt when the account's avatar changes.
      ListenableBuilder(
        listenable: widget.dependencies.sessionController,
        builder: (context, _) => WorkspaceHeader(
          compact: compact,
          feed: true,
          onOpenNotifications: _openNotifications,
          unreadNotifications: _unreadNotifications,
          handle: widget.dependencies.sessionController.session?.handle ?? '',
          avatar: widget.dependencies.service.avatarImage(
            widget.dependencies.sessionController.avatar,
          ),
          onOpenAdmin: !widget.dependencies.sessionController.isAdmin
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AdminScreen(dependencies: widget.dependencies),
                  ),
                ),
          onOpenProfile: () => showProfileMenu(context, widget.dependencies),
        ),
      );

  List<Widget> _feedSlivers(double horizontalPad, {required double bottom}) {
    final posts = model.followingPosts;
    return [
      // The person's assistant leads their home: the brief, what waits on
      // them and what their agents suggest.
      SliverPadding(
        padding: EdgeInsets.fromLTRB(horizontalPad, 4, horizontalPad, 0),
        sliver: SliverToBoxAdapter(
          child: HomeAssistant(
            key: const ValueKey('home-assistant'),
            dependencies: widget.dependencies,
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 12),
        sliver: SliverToBoxAdapter(child: _FeedHeader(count: posts.length)),
      ),
      if (posts.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyFeed(
            message:
                'Nothing here yet — follow people or join spaces to fill your feed.',
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, bottom),
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
                onShared: model.load,
              );
            },
          ),
        ),
      if (model.loadingMore) const SliverToBoxAdapter(child: SkeletonPost()),
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
      old.compact != compact || old.model != model || old.onSearch != onSearch;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final progress = (shrinkOffset / maxExtent).clamp(0.0, 1.0);
    return _HeroContent(
      progress: progress,
      compact: compact,
      onSearch: onSearch,
    );
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
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: fade,
              child: CustomPaint(
                painter: GlowPainter(scheme.primary, scheme.tertiary),
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Opacity(
            opacity: fade,
            child: Transform.translate(
              offset: Offset(0, -progress * 8),
              child: _SearchBar(onTap: () => onSearch(''), compact: compact),
            ),
          ),
        ),
      ],
    );
  }
}

/// Floating pill of captioned tabs for the phone home. The bar itself is a
/// capsule; the selected tab is a rounded pill surface behind its icon and
/// caption.
class HomeTabBar extends StatelessWidget {
  const HomeTabBar({super.key, required this.tab, required this.onSelect});

  /// Height of the capsule, before the float gap and the home indicator.
  static const height = 64.0;

  /// Width of one tab. The capsule hugs these instead of spanning the screen.
  static const tabWidth = 72.0;

  /// Space between the capsule and the screen edge or home indicator.
  static const floatGap = 10.0;

  /// How far the pill reaches up from the bottom of the screen.
  static double occupied(BuildContext context) =>
      height + floatGap + MediaQuery.viewPaddingOf(context).bottom;

  final HomeMobileTab tab;
  final ValueChanged<HomeMobileTab> onSelect;

  static const _tabs = <_HomeTabSpec>[
    _HomeTabSpec(
      HomeMobileTab.chats,
      'Chats',
      Icons.forum_outlined,
      Icons.forum_rounded,
    ),
    _HomeTabSpec(
      HomeMobileTab.desk,
      'Desk',
      Icons.widgets_outlined,
      Icons.widgets_rounded,
    ),
    _HomeTabSpec(
      HomeMobileTab.feed,
      'Feed',
      Icons.dynamic_feed_outlined,
      Icons.dynamic_feed_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final indicator = dark
        ? Colors.white.withValues(alpha: .16)
        : Colors.white.withValues(alpha: .94);
    return Padding(
      padding: EdgeInsets.only(
        bottom: floatGap + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? .35 : .14),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: GlassSurface(
            alpha: AppSurfaces.overlayAlpha,
            blur: AppSurfaces.blurSigma,
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      left: tabWidth * tab.index + 2,
                      width: tabWidth - 4,
                      top: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: indicator,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final spec in _tabs)
                          SizedBox(
                            width: tabWidth,
                            child: _HomeTabButton(
                              spec: spec,
                              selected: spec.tab == tab,
                              onTap: () => onSelect(spec.tab),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeTabSpec {
  const _HomeTabSpec(this.tab, this.label, this.icon, this.selectedIcon);

  final HomeMobileTab tab;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _HomeTabButton extends StatelessWidget {
  const _HomeTabButton({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final _HomeTabSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? spec.selectedIcon : spec.icon,
              size: 22,
              color: color,
            ),
            const SizedBox(height: 2),
            Text(
              spec.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.1,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
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
          child: GlassSurface(
            alpha: AppSurfaces.cardAlpha,
            blur: AppSurfaces.blurSigma,
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: SizedBox(
              height: _HeroContent._barHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      color: scheme.onSurfaceVariant,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Search Aseman…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                title,
                style: TextStyle(
                  fontSize: 22,
                  letterSpacing: -.3,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$count ${count == 1 ? 'post' : 'posts'}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.onSecondaryContainer,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({this.message});
  final String? message;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: ShapeDecoration(
              color: scheme.secondaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: Icon(
              Icons.search_off_rounded,
              size: 34,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            message ?? 'No matching results',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Try a different search or tab',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Chrome around the desktop chats and posts rails.
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
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .12),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: GlassSurface(
          alpha: AppSurfaces.cardAlpha,
          blur: AppSurfaces.blurSigma,
          borderRadius: BorderRadius.circular(30),
          child: SizedBox.expand(child: child),
        ),
      ),
    );
  }
}
