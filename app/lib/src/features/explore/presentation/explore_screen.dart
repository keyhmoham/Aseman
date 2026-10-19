import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../data/repositories/room_repository.dart';
import '../../../shared/widgets/app_panel.dart';
import '../../../shared/widgets/page_scaffold.dart';
import '../../../shared/widgets/responsive_grid.dart';
import '../../../shared/widgets/status_tag.dart';
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
    'Traders',
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
      subtitle: 'Find traders, agents, apps, and public rooms',
      child: AnimatedBuilder(
          animation: model,
          builder: (_, __) => ListView(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
                  children: [
                    TextField(
                        onChanged: (v) => setState(() => query = v),
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search_rounded),
                            hintText: 'Search agents, rooms, traders, apps…')),
                    const SizedBox(height: 16),
                    SizedBox(
                        height: 38,
                        child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: categories.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (_, index) => FilterChip(
                                selected: model.selectedCategory == index,
                                onSelected: (_) => model.selectCategory(index),
                                label: Text(categories[index])))),
                    const SizedBox(height: 24),
                    const Text('🔥 Trending AI agents',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    if (_loadingAgents)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_visibleAgents.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text('No agents match "$query".',
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ),
                      )
                    else
                      ResponsiveGrid(
                          children: _visibleAgents
                              .take(12)
                              .map((l) => _AgentCard(
                                    l.name,
                                    l.description.isEmpty
                                        ? '${l.kindLabel} · ${l.installs} installs'
                                        : l.description,
                                    '${l.installs} installs',
                                    l.isApp
                                        ? AppColors.primary
                                        : AppColors.warning,
                                  ))
                              .toList()),
                    const SizedBox(height: 24),
                    const Text('🏆 Top performing rooms',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    ResponsiveGrid(
                        children: model.rooms
                            .map((room) => InkWell(
                                onTap: widget.openRoom,
                                child: AppPanel(
                                    title: room.name,
                                    child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(room.members,
                                              style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant)),
                                          Text(room.status,
                                              style: const TextStyle(
                                                  color: AppColors.success))
                                        ]))))
                            .toList()),
                  ])));
}

class _AgentCard extends StatelessWidget {
  const _AgentCard(this.name, this.description, this.roi, this.color);
  final String name, description, roi;
  final Color color;
  @override
  Widget build(BuildContext context) => AppPanel(
      title: name,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12)),
        const SizedBox(height: 12),
        Row(children: [
          StatusTag(roi, AppColors.success),
          const Spacer(),
          Icon(Icons.extension_rounded, color: color, size: 18)
        ])
      ]));
}
