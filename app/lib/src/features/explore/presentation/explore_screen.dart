import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../data/models/bot.dart';
import '../../../data/repositories/room_repository.dart';
import '../../../shared/widgets/bot_avatar.dart';
import '../../../shared/widgets/page_scaffold.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/responsive_grid.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';
import 'explore_view_model.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen(
      {super.key,
      required this.repository,
      required this.openRoom,
      this.dependencies});
  final RoomRepository repository;
  final VoidCallback openRoom;
  final AppDependencies? dependencies;
  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  late final ExploreViewModel model;
  List<MarketListing> _agents = [];
  bool _loadingAgents = true;
  String query = '';
  static const categories = [
    'Trending',
    'People',
    'AI agents',
    'Apps',
    'Rooms'
  ];
  @override
  void initState() {
    super.initState();
    model = ExploreViewModel(widget.repository);
    unawaited(model.load());
    _loadAgents();
  }

  Future<void> _loadAgents() async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() => _loadingAgents = false);
      return;
    }
    try {
      final results = await Future.wait([
        deps.service.fetchMarket(type: 'agent', limit: 20),
        deps.service.fetchMarket(type: 'tool', limit: 20),
      ]);
      if (!mounted) return;
      setState(() {
        _agents = [
          ...(results[0] as List).cast<MarketListing>(),
          ...(results[1] as List).cast<MarketListing>()
        ];
        _loadingAgents = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingAgents = false);
    }
  }

  List<MarketListing> get _visibleAgents {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _agents;
    return _agents
        .where((a) =>
            a.name.toLowerCase().contains(q) ||
            a.description.toLowerCase().contains(q))
        .toList();
  }

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FeaturePage(
      title: 'Explore',
      subtitle: 'Find people, agents, apps, and public rooms',
      icon: Icons.explore_rounded,
      child: AnimatedBuilder(
          animation: model,
          builder: (_, __) {
            final compact = MediaQuery.sizeOf(context).width < 720;
            return ListView(
                padding: AppSpacing.pagePadding(compact)
                    .copyWith(bottom: AppSpacing.xl - 4, top: 0),
                children: [
                  SoftSearchField(
                    hintText: 'Search agents, rooms, people, apps…',
                    onChanged: (v) => setState(() => query = v),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        for (var index = 0;
                            index < categories.length;
                            index++)
                          FilterChip(
                              selected: model.selectedCategory == index,
                              onSelected: (_) => model.selectCategory(index),
                              label: Text(categories[index])),
                      ]),
                  const SizedBox(height: AppSpacing.xl - 4),
                  const SkySectionHeader(
                    dense: true,
                    icon: Icons.trending_up_rounded,
                    title: 'Trending agents & apps',
                    subtitle: 'Fresh listings from the market',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (_loadingAgents)
                    const SkeletonGrid(
                        itemCount: 4,
                        maxCrossAxisExtent: 320,
                        mainAxisExtent: 120)
                  else if (_visibleAgents.isEmpty)
                    PanelEmpty(
                      icon: Icons.search_off_rounded,
                      title: query.trim().isEmpty
                          ? 'Nothing to explore yet'
                          : 'No matches',
                      message: query.trim().isEmpty
                          ? 'Published agents and apps will show up here.'
                          : 'Nothing matches “$query”. Try another search.',
                    )
                  else
                    ResponsiveGrid(
                        children: _visibleAgents
                            .take(12)
                            .map((l) => _ExploreListingCard(l))
                            .toList()),
                  const SizedBox(height: AppSpacing.xl - 4),
                  const SkySectionHeader(
                    dense: true,
                    icon: Icons.meeting_room_outlined,
                    title: 'Top rooms',
                    subtitle: 'Public spaces worth a look',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ResponsiveGrid(
                      children: model.rooms
                          .map((room) => _RoomCard(
                                name: room.name,
                                members: room.members,
                                status: room.status,
                                onTap: widget.openRoom,
                              ))
                          .toList()),
                ]);
          }));
}

class _ExploreListingCard extends StatelessWidget {
  const _ExploreListingCard(this.listing);
  final MarketListing listing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = listing.isApp ? AppColors.cyan : AppColors.primary;
    final description = listing.description.isEmpty
        ? '${listing.kindLabel} · ${listing.installs} installs'
        : listing.description;
    return SoftCard(
      showOrb: false,
      accent: color,
      padding: const EdgeInsets.all(AppSpacing.sm + 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          BotAvatar(
            bot: listing.bot ??
                Bot(
                  id: listing.botId,
                  ownerId: listing.publisherId,
                  accountId: '',
                  name: listing.name,
                  kind: listing.isApp ? 'tool' : 'agent',
                  vmType: '',
                  status: '',
                  avatar: listing.avatar,
                ),
            radius: 17,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(listing.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14,
                    letterSpacing: -.2,
                    fontWeight: FontWeight.w800)),
          ),
          SoftMetaChip(label: listing.kindLabel.toUpperCase(), accent: color),
        ]),
        const SizedBox(height: 10),
        Text(description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: scheme.onSurfaceVariant, fontSize: 12, height: 1.35)),
        const SizedBox(height: 12),
        SoftMetaChip(
          icon: Icons.download_rounded,
          label: '${listing.installs} installs',
          accent: AppColors.success,
        ),
      ]),
    );
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.name,
    required this.members,
    required this.status,
    required this.onTap,
  });

  final String name;
  final String members;
  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftCard(
      onTap: onTap,
      showOrb: false,
      padding: const EdgeInsets.all(AppSpacing.sm + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14,
                  letterSpacing: -.2,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(members,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
              SoftMetaChip(label: status, accent: AppColors.success),
            ],
          ),
        ],
      ),
    );
  }
}
