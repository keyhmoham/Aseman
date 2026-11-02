import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/halo_ring_cache.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glow_painter.dart';
import '../../../shared/widgets/notifications_menu.dart';
import '../../../shared/widgets/profile_menu.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../../shared/widgets/workspace_header.dart';
import '../../../shared/widgets/workspace_panel_motion.dart';
import '../../admin/presentation/admin_screen.dart';
import '../../assistant/assistant.dart';
import '../../desk/presentation/widgets_library.dart';
import '../../home/presentation/workspace_screen.dart' show showExplore;
import '../../messenger/presentation/chat_page.dart';
import '../../messenger/presentation/messenger_panel.dart';
import '../domain/feed_post.dart';
import 'feed_post_card.dart';
import 'post_editor.dart';
import 'search_feed_view_model.dart';

/// Landing page. On a wide screen the chats sit in the left rail, Aseman
/// (chat + desk) in the center, and Explore (posts) in the right rail. On a
/// phone a floating pill switches Chats, Explore and You — Aseman lives in
/// the chats list (and stays centered on desktop). You is the former
/// top-right profile sheet.
enum HomeMobileTab { chats, explore, you }

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
  ChatSummary? _asemanChat;
  Object? _asemanError;
  bool _asemanLoading = true;

  @override
  void initState() {
    super.initState();
    _mobileTab = widget.initialMobileTab;
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
    unawaited(_loadAseman());
    motion.forward();
  }

  Future<void> _loadAseman() async {
    try {
      final chat = await widget.dependencies.service.openSaved();
      if (!mounted) return;
      setState(() {
        _asemanChat = chat;
        _asemanLoading = false;
        _asemanError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _asemanError = e;
        _asemanLoading = false;
      });
    }
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

  /// Full-bleed like Chats / Explore: glass fills under the floating tab bar;
  /// [bottomInset] is reserved inside chat/desk content only.
  Widget _asemanPane({required double bottomInset}) {
    if (_asemanLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_asemanChat == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _asemanError == null
                    ? 'Could not open Aseman'
                    : 'Could not open Aseman: $_asemanError',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _asemanLoading = true;
                    _asemanError = null;
                  });
                  unawaited(_loadAseman());
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    return ChatPage(
      dependencies: widget.dependencies,
      chat: _asemanChat!,
      embedded: true,
      bottomInset: bottomInset,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = _compact;
    final showComposer = !compact || _mobileTab == HomeMobileTab.explore;
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
                    Widget glassTab(Widget child) => GlassSurface(
                      alpha: AppSurfaces.cardAlpha,
                      blur: AppSurfaces.blurSigma,
                      borderRadius: BorderRadius.zero,
                      border: false,
                      child: child,
                    );
                    return IndexedStack(
                      index: _mobileTab.index,
                      sizing: StackFit.expand,
                      children: [
                        // App-bar inset lives inside each tab's scroll (like
                        // Explore) so content can pass under the floating bar.
                        glassTab(
                          MessengerPanel(
                            dependencies: widget.dependencies,
                            embedded: true,
                            topContentInset: appBarInset,
                            onOpenSpaceRoom: widget.onOpenSpaceRoom == null
                                ? null
                                : _enterWorkspaceRoom,
                            onOpenWorkspace: widget.onOpenWorkspace == null
                                ? null
                                : _enterWorkspace,
                          ),
                        ),
                        WorkspacePanelMotion(
                          animation: motion,
                          hiddenOffset: WorkspacePanelMotions.mobileOffset,
                          scaleFrom: WorkspacePanelMotions.mobileScale,
                          child: _feedScroll(
                            compact: true,
                            topInset: appBarInset,
                          ),
                        ),
                        glassTab(_youTab(topInset: appBarInset)),
                      ],
                    );
                  }
                  // Chats on the left, Aseman chat/desk in the center, Explore
                  // on the right.
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
                                  onOpenWorkspace:
                                      widget.onOpenWorkspace == null
                                      ? null
                                      : _enterWorkspace,
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
                            child: SizedBox(
                              height: railHeight,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(30),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black
                                          .withValues(alpha: .12),
                                      blurRadius: 30,
                                      offset: const Offset(0, 12),
                                    ),
                                  ],
                                ),
                                child: GlassSurface(
                                  alpha: AppSurfaces.cardAlpha,
                                  blur: AppSurfaces.blurSigma,
                                  borderRadius: BorderRadius.circular(30),
                                  child: _asemanPane(bottomInset: 0),
                                ),
                              ),
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
              child: ListenableBuilder(
                listenable: widget.dependencies.sessionController,
                builder: (context, _) => HomeTabBar(
                  tab: _mobileTab,
                  onSelect: _setMobileTab,
                  handle: widget.dependencies.sessionController.session
                          ?.handle ??
                      '',
                  accountId: widget.dependencies.sessionController.session
                          ?.accountId ??
                      '',
                  avatar: widget.dependencies.service.avatarImage(
                    widget.dependencies.sessionController.avatar,
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: !showComposer
          ? null
          : Padding(
              padding: EdgeInsets.only(
                bottom: compact ? _fabNavLift(context) : 0,
              ),
              child: SkyFab(
                heroTag: 'feed-composer',
                onPressed: _openComposer,
                icon: Icons.edit_rounded,
                label: 'Post',
                tooltip: 'New post',
              ),
            ),
    );
  }

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
          accountId:
              widget.dependencies.sessionController.session?.accountId ?? '',
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
          onOpenWidgetsLibrary: () => showWidgetsLibrary(
            context,
            widget.dependencies,
            onOpenSpace: widget.onOpenWorkspace == null
                ? null
                : (name) => unawaited(_enterWorkspace(name)),
          ),
          onOpenProfile: compact
              ? null
              : () => showProfileMenu(context, widget.dependencies),
        ),
      );

  /// Phone "You" tab — same body as the former top-right profile sheet.
  /// [topInset] clears the floating app bar on first paint; scrolling passes
  /// under it (same as Explore).
  Widget _youTab({required double topInset}) {
    final bottom = 16 + HomeTabBar.occupied(context);
    return ListenableBuilder(
      listenable: widget.dependencies.sessionController,
      builder: (context, _) => ListView(
        padding: EdgeInsets.only(top: topInset, bottom: bottom),
        children: [
          ProfileMenuBody(
            dependencies: widget.dependencies,
            showAdmin: widget.dependencies.sessionController.isAdmin,
            showMessages: false,
            onSelect: (action) => dispatchProfileAction(
              context,
              widget.dependencies,
              action,
            ),
          ),
        ],
      ),
    );
  }

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
/// caption. You uses the signed-in account's avatar instead of a glyph.
class HomeTabBar extends StatelessWidget {
  const HomeTabBar({
    super.key,
    required this.tab,
    required this.onSelect,
    this.handle = '',
    this.accountId = '',
    this.avatar,
  });

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
  final String handle;
  final String accountId;
  final ImageProvider? avatar;

  static const _tabs = <_HomeTabSpec>[
    _HomeTabSpec(
      HomeMobileTab.chats,
      'Chats',
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum_rounded,
    ),
    _HomeTabSpec(
      HomeMobileTab.explore,
      'Explore',
      icon: Icons.explore_outlined,
      selectedIcon: Icons.explore_rounded,
    ),
    _HomeTabSpec(
      HomeMobileTab.you,
      'You',
      avatar: true,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
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
                color: Colors.black.withValues(alpha: dark ? .30 : .12),
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
                        decoration: AppFab.tabIndicatorOf(scheme, radius: 999),
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
                              handle: handle,
                              accountId: accountId,
                              avatar: avatar,
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
  const _HomeTabSpec(
    this.tab,
    this.label, {
    this.icon,
    this.selectedIcon,
    this.avatar = false,
  });

  final HomeMobileTab tab;
  final String label;
  final IconData? icon;
  final IconData? selectedIcon;
  final bool avatar;
}

class _HomeTabButton extends StatelessWidget {
  const _HomeTabButton({
    required this.spec,
    required this.selected,
    required this.onTap,
    this.handle = '',
    this.accountId = '',
    this.avatar,
  });

  final _HomeTabSpec spec;
  final bool selected;
  final VoidCallback onTap;
  final String handle;
  final String accountId;
  final ImageProvider? avatar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    final initials = handle.isEmpty ? '?' : handle[0].toUpperCase();
    return Semantics(
      button: true,
      selected: selected,
      label: spec.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (spec.avatar)
              HaloRing(
                pad: 1.6,
                identity: HaloRingCache.person(accountId),
                accent: color,
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: color.withValues(alpha: .18),
                  foregroundImage: avatar,
                  onForegroundImageError: avatar == null ? null : (_, __) {},
                  child: Text(
                    initials,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      color: color,
                    ),
                  ),
                ),
              )
            else
              Icon(
                selected ? spec.selectedIcon! : spec.icon!,
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
