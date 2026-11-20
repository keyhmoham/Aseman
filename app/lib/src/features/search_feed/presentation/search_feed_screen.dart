import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/app_layout.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/layout/split_pane.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/aseman_tokens.dart';
import '../../../core/theme/halo_ring_cache.dart';
import '../../../core/theme/shell_layout.dart';
import '../../../core/theme/shell_layout_builder.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_ui_spec.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/avatar_face.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glow_painter.dart';
import '../../../shared/widgets/notifications_menu.dart';
import '../../../shared/widgets/profile_menu.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../../shared/widgets/theme_slot_host.dart';
import '../../../shared/widgets/workspace_header.dart';
import '../../../shared/widgets/workspace_panel_motion.dart';
import '../../assistant/assistant.dart';
import '../../desk/presentation/widgets_library.dart';
import '../../home/presentation/workspace_entry.dart';
import '../../messenger/presentation/chat_page.dart';
import '../../messenger/presentation/messenger_panel.dart';
import '../domain/feed_post.dart';
import 'feed_post_card.dart';
import 'post_editor.dart';
import 'search_feed_view_model.dart';

/// Landing page. On a wide screen the feed sits to the left of Aseman
/// (chat + desk), which fills the right side. On a phone a floating pill
/// switches Chats, Explore and You — Aseman lives in the chats list. You is
/// the former top-right profile sheet.
enum HomeMobileTab { chats, explore, you }

class SearchFeedScreen extends StatefulWidget {
  const SearchFeedScreen({
    super.key,
    required this.dependencies,
    this.workspace = 'Home',
    this.onOpenWorkspace,
    this.onOpenSpaceRoom,
    this.initialMobileTab = HomeMobileTab.chats,
    this.desktopShell = false,
  });

  final AppDependencies dependencies;
  final String workspace;
  final ValueChanged<String>? onOpenWorkspace;

  /// Desktop shell: the window already has a navigation rail, so this screen
  /// always uses the desktop pane layout and never the phone tab shell.
  final bool desktopShell;

  /// Opens a project on the workspace page with [roomName] / [roomId]
  /// already selected (desk, chat, and the rest of that room).
  final void Function(
    String spaceId,
    String spaceName,
    String roomName,
    String roomId,
  )?
  onOpenSpaceRoom;

  /// Which phone tab to show on mount. Chats on first land and when the
  /// workspace Home button returns here.
  final HomeMobileTab initialMobileTab;

  @override
  State<SearchFeedScreen> createState() => _SearchFeedScreenState();
}

class _SearchFeedScreenState extends State<SearchFeedScreen>
    with TickerProviderStateMixin {
  /// The posts pane's name in [PaneLayout]: its width and whether it is hidden.
  static const _feedPaneKey = 'home.feed';

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

  late String _mobileSlot;
  ChatSummary? _asemanChat;
  Object? _asemanError;
  bool _asemanLoading = true;

  @override
  void initState() {
    super.initState();
    _mobileSlot = switch (widget.initialMobileTab) {
      HomeMobileTab.chats => FeatureSlots.homeChats,
      HomeMobileTab.explore => FeatureSlots.homeExplore,
      HomeMobileTab.you => FeatureSlots.homeYou,
    };
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
    // Compact: the workspace is pushed over the feed like a direct chat, so
    // the feed stays as it is underneath instead of animating away.
    if (!_compact) await motion.reverse();
    if (mounted) open(name);
  }

  /// Opens a project with [roomName] selected, once the feed's panels have left.
  Future<void> _enterWorkspaceRoom(
    String spaceId,
    String name,
    String roomName,
    String roomId,
  ) async {
    final open = widget.onOpenSpaceRoom;
    if (open == null || motion.isAnimating) return;
    // Compact: pushed over the feed like a direct chat (no animate-away).
    if (!_compact) await motion.reverse();
    if (mounted) open(spaceId, name, roomName, roomId);
  }

  bool get _compact =>
      !widget.desktopShell &&
      MediaQuery.sizeOf(context).width < Breakpoints.expanded;

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

  void _setMobileSlot(String slot) {
    if (_mobileSlot == slot) return;
    setState(() => _mobileSlot = slot);
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
  /// content and does not reserve layout space; the button's own margin is 16.
  double _fabNavLift(BuildContext context) {
    const margin = 16.0;
    const gap = 12.0;
    return (HomeTabBar.occupied(context) + gap - margin).clamp(
      0.0,
      double.infinity,
    );
  }

  bool _feedComposerVisible(bool phone) {
    if (themeSlotDisabled(context, FeatureSlots.homeComposer) ||
        themeSlotDisabled(context, ThemeChromeSlots.feedComposer)) {
      return false;
    }
    if (!phone) return true;
    return shellOf(context).home.composerOn.contains(FeatureSlots.homeExplore);
  }

  Widget _feedComposerButton() => ThemeSlotHost(
    slot: FeatureSlots.homeComposer,
    child: ThemeSlotHost(
      slot: ThemeChromeSlots.feedComposer,
      child: SkyFab(
        heroTag: 'feed-composer',
        onPressed: _openComposer,
        icon: Icons.edit_rounded,
        label: 'Post',
        tooltip: 'New post',
      ),
    ),
  );

  /// Posts column with the composer pinned to that pane, not the scaffold.
  ///
  /// [phone] is the home tab layout. The search chrome stays compact in both
  /// the phone Explore tab and the wide posts pane.
  Widget _feedPane({required bool phone, required double topInset}) {
    // Phones put Post in the Following header instead of floating it over
    // the posts.
    final showComposer = _feedComposerVisible(phone) && !phone;
    return Stack(
      fit: StackFit.expand,
      children: [
        _feedScroll(
          compact: true,
          topInset: topInset,
          phone: phone,
          reserveComposer: showComposer,
        ),
        if (showComposer)
          PositionedDirectional(
            end: 16,
            bottom: phone ? 16 + _fabNavLift(context) : 16,
            child: _feedComposerButton(),
          ),
      ],
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
                    ? 'Could not open Decillion assistant'
                    : 'Could not open Decillion assistant: $_asemanError',
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
    final appBarInset = FloatingAppBarLayout.contentInsetOf(context, compact);
    return Scaffold(
      extendBody: compact,
      body: Stack(
        children: [
          if (compact && ThemeChrome.paintsAtmosphere(context))
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
                      alpha: AppSurfaces.cardAlphaOf(context),
                      blur: AppSurfaces.blurSigmaOf(context),
                      borderRadius: BorderRadius.zero,
                      border: false,
                      // Kashi: tabs sit on the limestone / night page so
                      // their cards read as raised.
                      color: ThemeChrome.isKashi(context)
                          ? Theme.of(context).scaffoldBackgroundColor
                          : null,
                      child: child,
                    );
                    final phoneTabs = homePhoneTabsOf(context);
                    final tabIndex = phoneTabs.isEmpty
                        ? 0
                        : phoneTabs
                              .indexWhere((t) => t.slot == _mobileSlot)
                              .clamp(0, phoneTabs.length - 1);
                    Widget tabBody(String slot) {
                      if (slot == FeatureSlots.homeChats) {
                        return glassTab(
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
                        );
                      }
                      if (slot == FeatureSlots.homeExplore) {
                        return WorkspacePanelMotion(
                          animation: motion,
                          hiddenOffset: WorkspacePanelMotions.mobileOffset,
                          scaleFrom: WorkspacePanelMotions.mobileScale,
                          child: _feedPane(phone: true, topInset: appBarInset),
                        );
                      }
                      if (slot == FeatureSlots.homeYou) {
                        return glassTab(_youTab(topInset: appBarInset));
                      }
                      final island = themeIslandOf(context, slot);
                      if (island != null) {
                        return glassTab(
                          Padding(
                            padding: EdgeInsets.only(top: appBarInset),
                            child: ThemeIslandHost(island: island),
                          ),
                        );
                      }
                      return glassTab(const SizedBox.shrink());
                    }

                    return IndexedStack(
                      index: tabIndex,
                      sizing: StackFit.expand,
                      children: [
                        for (final tab in phoneTabs) tabBody(tab.slot),
                      ],
                    );
                  }
                  // The bar sits only over the feed pane; Aseman (chat + desk)
                  // runs the full height beside it. When the feed pane is
                  // hidden (too narrow a window, or put away with its
                  // handle), the bar moves over Aseman so it is never lost.
                  final bar = _workspaceBar(context, false, anchored: true);
                  final room = AppWindowScope.supportingPane(context);
                  if (!room) {
                    return WorkspacePanelMotion(
                      animation: motion,
                      scaleFrom: WorkspacePanelMotions.centerScale,
                      child: AppPane(
                        child: Column(
                          children: [
                            bar,
                            Expanded(child: _asemanPane(bottomInset: 0)),
                          ],
                        ),
                      ),
                    );
                  }
                  return ListenableBuilder(
                    listenable: PaneLayout.instance,
                    builder: (context, _) {
                      final feedHidden = PaneLayout.instance.hidden(
                        _feedPaneKey,
                      );
                      return SplitPane(
                        storageKey: _feedPaneKey,
                        sideLabel: 'feed',
                        sideLeading: true,
                        collapsible: true,
                        minSideWidth: 240,
                        minMainWidth: AppLayout.flexiblePaneMin,
                        defaultSideWidth: (total) => AppLayout.paneWidths(
                          innerWidth: total,
                          leading: false,
                          trailing: true,
                        ).trailing,
                        side: WorkspacePanelMotion(
                          animation: motion,
                          hiddenOffset: WorkspacePanelMotions.left,
                          child: AppPane(
                            child: Column(
                              children: [
                                if (!feedHidden) bar,
                                Expanded(
                                  key: const ValueKey('home-feed'),
                                  child: _feedPane(phone: false, topInset: 0),
                                ),
                              ],
                            ),
                          ),
                        ),
                        main: WorkspacePanelMotion(
                          animation: motion,
                          scaleFrom: WorkspacePanelMotions.centerScale,
                          child: AppPane(
                            child: Column(
                              children: [
                                if (feedHidden) bar,
                                Expanded(
                                  key: const ValueKey('home-assistant-pane'),
                                  child: _asemanPane(bottomInset: 0),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          // Phones keep the floating pill. Desktop draws its bar in the page column.
          if (compact)
            SafeArea(
              bottom: false,
              child: ThemeSlotHost(
                slot: ThemeChromeSlots.floatingAppBar,
                child: ThemeSlotHost(
                  slot: FeatureSlots.workspaceHeader,
                  child: _workspaceBar(context, compact),
                ),
              ),
            ),
          if (compact)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ThemeSlotHost(
                slot: ThemeChromeSlots.homeTabBar,
                child: ListenableBuilder(
                  listenable: widget.dependencies.sessionController,
                  builder: (context, _) => HomeTabBar(
                    selectedSlot: _mobileSlot,
                    onSelect: _setMobileSlot,
                    handle:
                        widget.dependencies.sessionController.session?.handle ??
                        '',
                    accountId:
                        widget
                            .dependencies
                            .sessionController
                            .session
                            ?.accountId ??
                        '',
                    avatar: widget.dependencies.service.avatarImage(
                      widget.dependencies.sessionController.avatar,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Compact search bar over the posts. [topInset] is reserved
  /// inside the scroll so the first paint clears the floating app bar and
  /// later scroll passes under it.
  Widget _feedScroll({
    required bool compact,
    required double topInset,
    required bool phone,
    required bool reserveComposer,
  }) => LayoutBuilder(
    builder: (context, box) {
      final horizontalPad = math.max(16.0, (box.maxWidth - 760) / 2);
      // Clear the tab pill, and the Post button pinned in this pane.
      final bottom = phone
          ? 16 + HomeTabBar.occupied(context) + (reserveComposer ? 64.0 : 0.0)
          : (reserveComposer ? 88.0 : 32.0);
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
          ..._feedSlivers(horizontalPad, bottom: bottom, phone: phone),
        ],
      );
    },
  );

  Widget _workspaceBar(
    BuildContext context,
    bool compact, {
    bool anchored = false,
  }) =>
      // Rebuilt when the account's avatar changes.
      ListenableBuilder(
        listenable: widget.dependencies.sessionController,
        builder: (context, _) => WorkspaceHeader(
          compact: compact,
          anchored: anchored,
          feed: true,
          onOpenNotifications: _openNotifications,
          unreadNotifications: _unreadNotifications,
          handle: widget.dependencies.sessionController.session?.handle ?? '',
          accountId:
              widget.dependencies.sessionController.session?.accountId ?? '',
          avatar: widget.dependencies.service.avatarImage(
            widget.dependencies.sessionController.avatar,
          ),
          // Profile and admin live in Settings. Widgets stays: pinned windows
          // are not a settings section.
          onOpenWidgetsLibrary: () => showWidgetsLibrary(
            context,
            widget.dependencies,
            onOpenSpace: widget.onOpenWorkspace == null
                ? null
                : (name) => unawaited(_enterWorkspace(name)),
          ),
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
          ThemeSlotHost(
            slot: FeatureSlots.homeYou,
            child: ProfileMenuBody(
              dependencies: widget.dependencies,
              showAdmin: widget.dependencies.sessionController.isAdmin,
              onSelect: (action) => unawaited(
                dispatchProfileAction(context, widget.dependencies, action),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _feedSlivers(
    double horizontalPad, {
    required double bottom,
    bool phone = false,
  }) {
    final posts = model.followingPosts;
    return [
      // The person's assistant leads their home: the brief, what waits on
      // them and what their agents suggest.
      SliverPadding(
        padding: EdgeInsets.fromLTRB(horizontalPad, 4, horizontalPad, 0),
        sliver: SliverToBoxAdapter(
          child: ThemeSlotHost(
            slot: ThemeChromeSlots.feedAssistant,
            child: HomeAssistant(
              key: const ValueKey('home-assistant'),
              dependencies: widget.dependencies,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 12),
        sliver: SliverToBoxAdapter(
          child: _FeedHeader(
            count: posts.length,
            post: phone && _feedComposerVisible(true)
                ? ThemeSlotHost(
                    slot: FeatureSlots.homeComposer,
                    child: ThemeSlotHost(
                      slot: ThemeChromeSlots.feedComposer,
                      child: FilledButton.icon(
                        onPressed: _openComposer,
                        icon: const Icon(Icons.edit_rounded, size: 18),
                        label: const Text('Post'),
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.onSurface,
                          foregroundColor:
                              Theme.of(context).colorScheme.surface,
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                      ),
                    ),
                  )
                : null,
          ),
        ),
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
        if (ThemeChrome.paintsAtmosphere(context))
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
/// capsule; the selected tab is an M3 secondary-container indicator behind its
/// caption. You uses the signed-in account's avatar instead of a glyph.
class HomeTabBar extends StatelessWidget {
  const HomeTabBar({
    super.key,
    required this.selectedSlot,
    required this.onSelect,
    this.handle = '',
    this.accountId = '',
    this.avatar,
  });

  /// Fallback height when the pack does not set [AsemanTokens.navHeight].
  static const height = 64.0;

  /// Width of one tab. The capsule hugs these instead of spanning the screen.
  static const tabWidth = 72.0;

  /// Space between the capsule and the screen edge or home indicator.
  static const floatGap = 10.0;

  static double _barHeight(BuildContext context) {
    final h = AsemanTokens.maybeOf(context)?.navHeight;
    return (h == null || h <= 0) ? height : h;
  }

  /// How far the pill reaches up from the bottom of the screen.
  static double occupied(BuildContext context) {
    if (themeSlotDisabled(context, ThemeChromeSlots.homeTabBar)) return 0;
    return _barHeight(context) +
        floatGap +
        MediaQuery.viewPaddingOf(context).bottom;
  }

  final String selectedSlot;
  final ValueChanged<String> onSelect;
  final String handle;
  final String accountId;
  final ImageProvider? avatar;

  static _HomeTabSpec _specFor(ShellTabMeta meta) {
    if (meta.slot == FeatureSlots.homeYou) {
      return _HomeTabSpec(meta.slot, meta.label, avatar: true);
    }
    if (meta.slot == FeatureSlots.homeChats) {
      return _HomeTabSpec(
        meta.slot,
        meta.label,
        icon: Icons.forum_outlined,
        selectedIcon: Icons.forum_rounded,
      );
    }
    if (meta.slot == FeatureSlots.homeExplore) {
      return _HomeTabSpec(
        meta.slot,
        meta.label,
        icon: Icons.explore_outlined,
        selectedIcon: Icons.explore_rounded,
      );
    }
    return _HomeTabSpec(meta.slot, meta.label, icon: meta.icon);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final nav = tokens?.control('nav_pill');
    final capsuleRadius = nav?.borderRadius ?? BorderRadius.circular(999);
    final barH = _barHeight(context);
    final iconSize = tokens?.language.iconSize ?? 22;
    final metas = homePhoneTabsOf(context);
    final tabs = [for (final meta in metas) _specFor(meta)];
    if (tabs.isEmpty) {
      tabs.addAll([
        const _HomeTabSpec(
          FeatureSlots.homeChats,
          'Chats',
          icon: Icons.forum_outlined,
          selectedIcon: Icons.forum_rounded,
        ),
        const _HomeTabSpec(
          FeatureSlots.homeExplore,
          'Explore',
          icon: Icons.explore_outlined,
          selectedIcon: Icons.explore_rounded,
        ),
        const _HomeTabSpec(FeatureSlots.homeYou, 'You', avatar: true),
      ]);
    }
    final selectedIndex = tabs
        .indexWhere((s) => s.slot == selectedSlot)
        .clamp(0, tabs.length - 1);
    return Padding(
      padding: EdgeInsets.only(
        bottom: floatGap + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: capsuleRadius,
            boxShadow:
                tokens?.language.shadow.resolve(
                  scheme,
                  accent: scheme.primary,
                ) ??
                AppFab.glowOf(scheme),
          ),
          child: GlassSurface(
            alpha: AppSurfaces.overlayAlphaResolved(tokens),
            blur: AppSurfaces.blurSigmaResolved(tokens),
            borderRadius: capsuleRadius,
            child: SizedBox(
              height: barH,
              child: Padding(
                padding: EdgeInsets.all(nav?.paddingV.clamp(3, 10) ?? 5),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      left: tabWidth * selectedIndex + 2,
                      width: tabWidth - 4,
                      top: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: AppFab.tabIndicatorOf(
                          scheme,
                          tokens: tokens,
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final spec in tabs)
                          SizedBox(
                            width: tabWidth,
                            child: _HomeTabButton(
                              spec: spec,
                              selected: spec.slot == selectedSlot,
                              handle: handle,
                              accountId: accountId,
                              avatar: avatar,
                              iconSize: iconSize,
                              onTap: () => onSelect(spec.slot),
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
    this.slot,
    this.label, {
    this.icon,
    this.selectedIcon,
    this.avatar = false,
  });

  final String slot;
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
    this.iconSize = 22,
  });

  final _HomeTabSpec spec;
  final bool selected;
  final VoidCallback onTap;
  final String handle;
  final String accountId;
  final ImageProvider? avatar;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? AppFab.tabIndicatorInkOf(scheme)
        : scheme.onSurfaceVariant;
    final initials = handle.isEmpty ? '?' : handle[0].toUpperCase();
    final avatarR = (iconSize * .5).clamp(9.0, 14.0);
    return Semantics(
      button: true,
      selected: selected,
      label: spec.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // A pack can set a nav height shorter than icon + label (and the
        // avatar's halo adds more); scale the stack down to fit the pill
        // instead of overflowing it.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (spec.avatar)
                Builder(
                  builder: (context) {
                    final size = avatarR * 2;
                    final corners = context.avatarBorderRadius(size);
                    final face = AvatarFace(
                      size: size,
                      borderRadius: corners,
                      backgroundColor: color.withValues(alpha: .18),
                      foregroundImage: avatar,
                      onImageError: avatar == null ? null : (_, __) {},
                      child: Text(
                        initials,
                        style: TextStyle(
                          fontSize: avatarR * .9,
                          fontWeight: FontWeight.w800,
                          height: 1,
                          color: color,
                        ),
                      ),
                    );
                    return HaloRing(
                      pad: 1.6,
                      identity: HaloRingCache.person(accountId),
                      accent: color,
                      borderRadius: corners,
                      child: face,
                    );
                  },
                )
              else
                Icon(
                  selected ? spec.selectedIcon! : spec.icon!,
                  size: iconSize,
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
                  fontWeight: selected
                      ? ThemeChrome.selectedNavWeight(context)
                      : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
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
            alpha: AppSurfaces.cardAlphaOf(context),
            blur: AppSurfaces.blurSigmaOf(context),
            borderRadius: ThemeChrome.inputShell(context).radius,
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
  const _FeedHeader({required this.count, this.post});

  final int count;

  /// New-post button shown in place of the count (phones).
  final Widget? post;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const title = 'Following';
    const subtitle = 'People, agents & your spaces';
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
        if (post != null)
          post!
        else
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$count ${count == 1 ? 'post' : 'posts'}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
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
              color: scheme.surfaceContainerHighest,
              shape: RoundedRectangleBorder(
                borderRadius: AppShape.borderRadius(context, 24),
              ),
            ),
            child: Icon(
              Icons.search_off_rounded,
              size: 34,
              color: scheme.onSurfaceVariant,
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
