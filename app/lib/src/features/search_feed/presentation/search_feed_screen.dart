import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/glow_painter.dart';
import '../../../shared/widgets/mini_tag.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/profile_menu.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/spark_painter.dart';
import '../../../shared/widgets/status_tag.dart';
import '../../../shared/widgets/workspace_header.dart';
import '../../admin/presentation/admin_screen.dart';
import '../domain/feed_post.dart';
import '../domain/trader.dart';
import 'post_editor.dart';
import 'rich_post_content.dart';
import 'search_feed_view_model.dart';

/// Landing page: a Google-like search engine fused with a Global/Following
/// posts feed. The robot head + search bar live in a collapsible header and
/// the workspace switcher stays pinned on top.
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
    with SingleTickerProviderStateMixin {
  late final SearchFeedViewModel model;
  late final TabController tabs;
  final searchController = TextEditingController();
  final scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    model = SearchFeedViewModel(
      dependencies: widget.dependencies,
      workspace: widget.workspace,
    );
    tabs = TabController(length: 5, vsync: this)
      ..addListener(() {
        if (!tabs.indexIsChanging) setState(() {});
      });
    searchController.addListener(() => model.setQuery(searchController.text));
    scrollController.addListener(_onScroll);
    model.load();
  }

  void _onScroll() {
    if (!scrollController.hasClients) return;
    if (scrollController.position.extentAfter < 300 && tabs.index != 4) {
      unawaited(model.loadMore(tabs.index));
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
    searchController.dispose();
    scrollController.dispose();
    tabs.dispose();
    model.dispose();
    super.dispose();
  }

  void _openWorkspaces(BuildContext context) {
    showFloatingPanel(
      context,
      WorkspacePicker(
        current: model.workspace,
        dependencies: widget.dependencies,
        onPick: (name) {
          Navigator.pop(context);
          widget.onOpenWorkspace?.call(name);
        },
      ),
      barrierLabel: 'Workspaces',
    );
  }

  void _applySuggestion(String value) {
    searchController.text = value;
    searchController.selection = TextSelection.collapsed(offset: value.length);
  }

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
    final compact = MediaQuery.sizeOf(context).width < 820;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
            child: CustomPaint(
                painter: GlowPainter(scheme.primary, scheme.tertiary))),
        SafeArea(child: LayoutBuilder(builder: (context, box) {
          final horizontalPad = math.max(16.0, (box.maxWidth - 760) / 2);
          return AnimatedBuilder(
              animation: model,
              builder: (context, _) =>
                  CustomScrollView(controller: scrollController, slivers: [
                    SliverPersistentHeader(
                        pinned: true,
                        delegate: _FixedHeaderDelegate(
                            extent: 68,
                            child: _workspaceBar(context, compact, scheme))),
                    SliverPersistentHeader(
                        pinned: false,
                        delegate: _SearchHeroDelegate(
                            compact: compact,
                            controller: searchController,
                            model: model,
                            onSuggestion: _applySuggestion)),
                    SliverPersistentHeader(
                        pinned: true,
                        delegate: _FixedHeaderDelegate(
                            extent: 60,
                            child: _FeedTabs(tabs: tabs, compact: compact))),
                    ..._feedSlivers(horizontalPad),
                  ]));
        })),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'feed-composer',
        onPressed: _openComposer,
        icon: const Icon(Icons.edit_rounded, size: 18),
        label: const Text('Post'),
      ),
    );
  }

  Widget _workspaceBar(
          BuildContext context, bool compact, ColorScheme scheme) =>
      Container(
          decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: .96),
              border: Border(
                  bottom: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: .5)))),
          child: WorkspaceHeader(
              workspace: model.workspace,
              compact: compact,
              onOpenWorkspaces: () => _openWorkspaces(context),
              onOpenAdmin: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          AdminScreen(dependencies: widget.dependencies),
                    ),
                  ),
              onOpenProfile: () =>
                  showProfileMenu(context, widget.dependencies)));

  List<Widget> _feedSlivers(double horizontalPad) {
    if (tabs.index == 4) return _traderSlivers(horizontalPad);
    final posts = model.search(model.postsFor(tabs.index));
    return [
      SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 12),
          sliver: SliverToBoxAdapter(
              child: _FeedHeader(
                  tab: tabs.index,
                  count: posts.length,
                  workspace: model.workspace,
                  query: model.query))),
      if (posts.isEmpty)
        SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyFeed(
                message: tabs.index == 2
                    ? 'No workspace posts yet — create one in your workspace.'
                    : tabs.index == 3
                        ? 'You have not posted anything yet.'
                        : 'Nothing here yet.'))
      else
        SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, 32),
            sliver: SliverList.builder(
                itemCount: posts.length,
                itemBuilder: (context, index) => _FeedPostCard(
                    post: posts[index],
                    onToggleLike: () => _toggleLike(posts[index])))),
      if (model.loadingMore)
        const SliverToBoxAdapter(
            child: Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5))),
        )),
    ];
  }

  List<Widget> _traderSlivers(double horizontalPad) {
    final traders = model.searchTraders(model.traders);
    return [
      SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 12),
          sliver: SliverToBoxAdapter(
              child: _TraderHeader(count: traders.length, query: model.query))),
      if (traders.isEmpty)
        const SliverFillRemaining(hasScrollBody: false, child: _EmptyFeed())
      else ...[
        SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, 12),
            sliver: SliverToBoxAdapter(child: _TraderPodium(traders: traders))),
        if (traders.length > 3)
          SliverPadding(
              padding: EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, 32),
              sliver: SliverList.builder(
                  itemCount: traders.length - 3,
                  itemBuilder: (context, index) =>
                      _TraderRow(rank: index + 4, trader: traders[index + 3])))
        else
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    ];
  }
}

class _FixedHeaderDelegate extends SliverPersistentHeaderDelegate {
  _FixedHeaderDelegate({required this.extent, required this.child});
  final double extent;
  final Widget child;
  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;
  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox(height: extent, width: double.infinity, child: child);
  @override
  bool shouldRebuild(covariant _FixedHeaderDelegate old) =>
      old.extent != extent || old.child != child;
}

class _SearchHeroDelegate extends SliverPersistentHeaderDelegate {
  _SearchHeroDelegate({
    required this.compact,
    required this.controller,
    required this.model,
    required this.onSuggestion,
  });

  final bool compact;
  final TextEditingController controller;
  final SearchFeedViewModel model;
  final ValueChanged<String> onSuggestion;

  @override
  double get minExtent => 0;
  @override
  double get maxExtent => compact ? 318 : 360;
  @override
  bool shouldRebuild(covariant _SearchHeroDelegate old) =>
      old.compact != compact ||
      old.controller != controller ||
      old.model != model ||
      old.onSuggestion != onSuggestion;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final progress = (shrinkOffset / maxExtent).clamp(0.0, 1.0);
    return _HeroContent(
        progress: progress,
        compact: compact,
        controller: controller,
        onSuggestion: onSuggestion);
  }
}

class _HeroContent extends StatelessWidget {
  const _HeroContent({
    required this.progress,
    required this.compact,
    required this.controller,
    required this.onSuggestion,
  });

  final double progress;
  final bool compact;
  final TextEditingController controller;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final robotSize = compact ? 124.0 : 148.0;
    final fade = (1 - progress).clamp(0.0, 1.0);
    final robotScale = 1 - .45 * progress;
    final searchTop = 18 + robotSize + 26;
    final chipsTop = searchTop + 62 + 16;
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
                  scale: robotScale, child: _RobotHead(size: robotSize)))),
      Positioned(
          top: searchTop,
          left: 0,
          right: 0,
          child: Opacity(
              opacity: fade,
              child: Transform.translate(
                  offset: Offset(0, -progress * 12),
                  child: _BigSearchBar(
                      controller: controller, compact: compact)))),
      Positioned(
          top: chipsTop,
          left: 0,
          right: 0,
          child: Opacity(
              opacity: fade,
              child: _TrendingChips(onSuggestion: onSuggestion))),
    ]);
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
  const _BigSearchBar({required this.controller, required this.compact});
  final TextEditingController controller;
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
                              controller: controller,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w500),
                              textInputAction: TextInputAction.search,
                              decoration: InputDecoration(
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  hintText:
                                      'Search Tradera — signals, traders, agents…',
                                  hintStyle: TextStyle(
                                      fontSize: 15,
                                      color: scheme.onSurfaceVariant)))),
                      IconButton(
                          onPressed: () {},
                          icon: const Icon(Icons.mic_none_rounded)),
                      const SizedBox(width: 2),
                      IconButton.filled(
                          onPressed: () {},
                          icon: const Icon(Icons.arrow_upward_rounded)),
                    ])))));
  }
}

class _TrendingChips extends StatelessWidget {
  const _TrendingChips({required this.onSuggestion});
  final ValueChanged<String> onSuggestion;
  static const suggestions = [
    '\$BTC',
    '\$ETH',
    'AI agents',
    'Macro',
    'DeFi',
    'Whale alerts'
  ];
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: box.maxWidth - 24),
                child:
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < suggestions.length; i++) ...[
                    ActionChip(
                        avatar: const Icon(Icons.trending_up_rounded, size: 14),
                        label: Text(suggestions[i]),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onSuggestion(suggestions[i])),
                    if (i != suggestions.length - 1) const SizedBox(width: 8),
                  ],
                ])));
      });
}

class _FeedTabs extends StatelessWidget {
  const _FeedTabs({required this.tabs, required this.compact});
  final TabController tabs;
  final bool compact;
  @override
  Widget build(BuildContext context) => SegmentedTabBar(
        controller: tabs,
        compact: compact,
        labels: const ['Global', 'Following', 'Spaces', 'Me', 'Traders'],
        icons: const [
          Icons.public_rounded,
          Icons.person_pin_circle_outlined,
          Icons.workspaces_outline,
          Icons.person_outline,
          Icons.emoji_events_outlined,
        ],
      );
}

class _FeedHeader extends StatelessWidget {
  const _FeedHeader({
    required this.tab,
    required this.count,
    required this.workspace,
    required this.query,
  });

  final int tab;
  final int count;
  final String workspace;
  final String query;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmed = query.trim();
    final (title, subtitle) = switch (tab) {
      0 => ('Global feed', 'Public signals, agents and ideas across Tradera'),
      1 => ('Following', 'People and agents you follow · $workspace context'),
      2 => ('Spaces', 'Private posts from all your workspaces'),
      3 => ('My posts', 'Everything you have published'),
      _ => ('Traders leaderboard', 'Top performers ranked by verified score'),
    };
    final shownSubtitle = trimmed.isEmpty
        ? subtitle
        : '${count} result${count == 1 ? '' : 's'} for “$trimmed”';
    return Row(children: [
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        Text(shownSubtitle,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant))
      ])),
      Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(12)),
          child: Text('$count',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: scheme.onPrimaryContainer))),
      const SizedBox(width: 10),
      IconButton(
          tooltip: 'Filter feed',
          onPressed: () {},
          icon: const Icon(Icons.tune_rounded, size: 20))
    ]);
  }
}

class _TraderHeader extends StatelessWidget {
  const _TraderHeader({required this.count, required this.query});
  final int count;
  final String query;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmed = query.trim();
    final subtitle = trimmed.isEmpty
        ? 'Top performers ranked by verified score'
        : '${count} trader${count == 1 ? '' : 's'} for “$trimmed”';
    return Row(children: [
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Traders leaderboard',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        Text(subtitle,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant))
      ])),
      Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(12)),
          child: Text('$count',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: scheme.onPrimaryContainer))),
      const SizedBox(width: 10),
      IconButton(
          tooltip: 'Filter leaders',
          onPressed: () {},
          icon: const Icon(Icons.tune_rounded, size: 20))
    ]);
  }
}

class _TraderPodium extends StatelessWidget {
  const _TraderPodium({required this.traders});
  final List<Trader> traders;
  @override
  Widget build(BuildContext context) {
    final shown = traders.take(3).toList();
    return switch (shown.length) {
      3 => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
              child: _PodiumCard(
                  rank: 2, medal: const Color(0xFFB0BEC5), trader: shown[1])),
          const SizedBox(width: 10),
          Expanded(
              child: _PodiumCard(
                  rank: 1,
                  medal: const Color(0xFFFFC857),
                  trader: shown[0],
                  featured: true)),
          const SizedBox(width: 10),
          Expanded(
              child: _PodiumCard(
                  rank: 3, medal: const Color(0xFFD8A47A), trader: shown[2])),
        ]),
      2 => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
              child: _PodiumCard(
                  rank: 1,
                  medal: const Color(0xFFFFC857),
                  trader: shown[0],
                  featured: true)),
          const SizedBox(width: 10),
          Expanded(
              child: _PodiumCard(
                  rank: 2, medal: const Color(0xFFB0BEC5), trader: shown[1])),
        ]),
      1 => _PodiumCard(
          rank: 1,
          medal: const Color(0xFFFFC857),
          trader: shown[0],
          featured: true),
      _ => const SizedBox.shrink(),
    };
  }
}

class _PodiumCard extends StatelessWidget {
  const _PodiumCard({
    required this.rank,
    required this.medal,
    required this.trader,
    this.featured = false,
  });

  final int rank;
  final Color medal;
  final Trader trader;
  final bool featured;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: EdgeInsets.all(featured ? 16 : 12),
        decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  medal.withValues(alpha: .18),
                  scheme.surfaceContainerLow.withValues(alpha: .9)
                ]),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: medal.withValues(alpha: .45))),
        child: Column(children: [
          Row(children: [
            Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                    color: medal.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(9)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      featured
                          ? Icons.emoji_events_rounded
                          : Icons.military_tech_rounded,
                      size: 12,
                      color: medal),
                  const SizedBox(width: 4),
                  Text('#$rank',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          color: medal)),
                ])),
            const Spacer(),
            if (trader.verified)
              const Icon(Icons.verified_rounded,
                  size: 14, color: Colors.blueAccent),
          ]),
          const SizedBox(height: 10),
          AppAvatar(trader.initials,
              color: trader.color, radius: featured ? 26 : 20),
          const SizedBox(height: 8),
          Text(trader.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(trader.handle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          Text(trader.score.toStringAsFixed(1),
              style: TextStyle(
                  fontSize: featured ? 24 : 20,
                  fontWeight: FontWeight.w900,
                  color: scheme.primary)),
          const SizedBox(height: 2),
          Text('score',
              style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                MiniTag('ROI ${trader.roi}', AppColors.success),
                MiniTag('ACC ${trader.accuracy}', scheme.primary),
              ]),
        ]));
  }
}

class _TraderRow extends StatelessWidget {
  const _TraderRow({required this.rank, required this.trader});
  final int rank;
  final Trader trader;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final up = trader.change.startsWith('+');
    final changeColor = up ? AppColors.success : AppColors.danger;
    return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: .9),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .55))),
        child: Row(children: [
          SizedBox(
              width: 34,
              child: Center(
                  child: Text('#$rank',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w900)))),
          AppAvatar(trader.initials, color: trader.color, radius: 20),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Flexible(
                      child: Text(trader.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w800))),
                  if (trader.verified) ...[
                    const SizedBox(width: 5),
                    const Icon(Icons.verified_rounded,
                        size: 14, color: Colors.blueAccent),
                  ],
                ]),
                const SizedBox(height: 2),
                Text('${trader.handle} · ${trader.followers} followers',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 7),
                Row(children: [
                  MiniTag('ROI ${trader.roi}', AppColors.success),
                  const SizedBox(width: 6),
                  MiniTag('ACC ${trader.accuracy}', scheme.primary),
                ]),
              ])),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(trader.score.toStringAsFixed(1),
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: scheme.primary)),
            const SizedBox(height: 2),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(up ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                  size: 13, color: changeColor),
              const SizedBox(width: 3),
              Text(trader.change,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: changeColor)),
            ]),
          ]),
        ]));
  }
}

class _FeedPostCard extends StatelessWidget {
  const _FeedPostCard({required this.post, this.onToggleLike});
  final FeedPost post;
  final VoidCallback? onToggleLike;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: .9),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .55))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppAvatar(post.initials, color: post.color, radius: 19),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(children: [
                    Flexible(
                        child: Text(post.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w800))),
                    if (post.verified) ...[
                      const SizedBox(width: 5),
                      const Icon(Icons.verified_rounded,
                          size: 14, color: Colors.blueAccent),
                    ],
                  ]),
                  Text('${post.handle} · ${post.time}',
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
                ])),
            if (post.pinned)
              Icon(Icons.push_pin_rounded, size: 15, color: scheme.primary),
            IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () {},
                icon: const Icon(Icons.more_horiz_rounded, size: 18))
          ]),
          const SizedBox(height: 10),
          RichPostContent(post.body),
          if (post.chart) ...[
            const SizedBox(height: 12),
            Container(
                height: 84,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      post.color.withValues(alpha: .22),
                      scheme.primaryContainer.withValues(alpha: .16)
                    ]),
                    borderRadius: BorderRadius.circular(16)),
                child: Stack(fit: StackFit.expand, children: [
                  CustomPaint(
                      painter: SparkPainter(post.color),
                      child: const SizedBox.expand()),
                  Positioned(
                      left: 10,
                      top: 8,
                      child: MiniTag(post.coin ?? 'CHART', post.color))
                ])),
          ],
          const SizedBox(height: 12),
          Row(children: [
            StatusTag(post.tag, post.color),
            if (post.workspace != null) ...[
              const SizedBox(width: 6),
              MiniTag(post.workspace!.toUpperCase(), AppColors.primary),
            ],
            const Spacer(),
            InkWell(
              onTap: onToggleLike,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    post.liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 16,
                    color: post.liked
                        ? Colors.pinkAccent
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Text(post.likes,
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
                ]),
              ),
            ),
            const SizedBox(width: 14),
            _PostAction(
                icon: Icons.chat_bubble_outline_rounded, label: post.comments),
            const SizedBox(width: 14),
            const Icon(Icons.share_outlined, size: 16),
            const SizedBox(width: 14),
            const Icon(Icons.bookmark_border_rounded, size: 16),
          ]),
        ]));
  }
}

class _PostAction extends StatelessWidget {
  const _PostAction({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon,
            size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant))
      ]);
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({this.message});
  final String? message;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.search_off_rounded, size: 44, color: scheme.onSurfaceVariant),
      const SizedBox(height: 10),
      Text(message ?? 'No matching results',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text('Try a different search or tab',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))
    ]));
  }
}
