import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/post.dart';
import '../../../data/repositories/market_repository.dart';
import '../../../domain/models/market_quote.dart';
import '../../../shared/widgets/app_panel.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/page_scaffold.dart';
import '../../../shared/widgets/stat_card.dart';
import '../../../shared/widgets/status_tag.dart';
import 'home_view_model.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key,
      required this.repository,
      required this.openRoom,
      this.dependencies});
  final MarketRepository repository;
  final VoidCallback openRoom;
  final AppDependencies? dependencies;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomeViewModel model;
  List<SocialPost> _feed = [];
  List<Bot> _bots = [];
  int _balance = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    model = HomeViewModel(widget.repository);
    unawaited(model.load());
    _loadPulse();
  }

  Future<void> _loadPulse() async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final results = await Future.wait([
        deps.service.fetchFeed(limit: 4),
        deps.service.fetchBots(),
        deps.service.fetchWallet(),
      ]);
      if (!mounted) return;
      setState(() {
        _feed = (results[0] as List).cast<SocialPost>();
        _bots = (results[1] as List).cast<Bot>();
        _balance = (results[2] as Wallet).available;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FeaturePage(
        title: 'Pulse',
        subtitle: 'Your market, agents, and rooms at a glance',
        actions: [
          FilledButton.icon(
              onPressed: widget.openRoom,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create room'))
        ],
        child: AnimatedBuilder(
            animation: model,
            builder: (context, _) {
              if (model.loading)
                return const Center(child: CircularProgressIndicator());
              if (model.error != null)
                return Center(
                    child: Text('Could not load market data: ${model.error}'));
              return LayoutBuilder(builder: (context, constraints) {
                final feed = ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 14, 24),
                    children: [
                      SizedBox(
                          height: 82,
                          child: ListView(
                              scrollDirection: Axis.horizontal,
                              children:
                                  model.quotes.map(_MarketTile.new).toList())),
                      const SizedBox(height: 16),
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_feed.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                              child: Text('No platform posts yet.',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant))),
                        )
                      else
                        ..._feed.map((p) => _FeedCard.fromPost(p)),
                    ]);
                if (constraints.maxWidth <= 1000) return feed;
                return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: feed),
                      SizedBox(
                          width: 330,
                          child: ListView(
                              padding: const EdgeInsets.fromLTRB(0, 0, 24, 24),
                              children: [
                                StatCard(
                                    title: 'Portfolio balance',
                                    value: formatLedgerCredits(_balance),
                                    change: 'from finance.wallet',
                                    color: AppColors.success),
                                const SizedBox(height: 12),
                                AppPanel(
                                    title: 'Active agents',
                                    child: _bots.isEmpty
                                        ? Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Text('No agents yet',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant)))
                                        : Column(
                                            children: _bots
                                                .where((b) => b.isAgent)
                                                .take(4)
                                                .map((b) => _AgentRow(
                                                    b.name,
                                                    b.status,
                                                    b.status == 'running'
                                                        ? AppColors.success
                                                        : Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant))
                                                .toList())),
                              ])),
                    ]);
              });
            }),
      );
}

class _MarketTile extends StatelessWidget {
  const _MarketTile(this.quote);
  final MarketQuote quote;
  @override
  Widget build(BuildContext context) => Container(
        width: 165,
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.all(14),
        decoration: AppSurfaces.cardDecoration(context),
        child: Row(children: [
          AppAvatar(quote.symbol[0], color: quote.color),
          const SizedBox(width: 8),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                Text(quote.symbol,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(quote.price,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                Text('${quote.change > 0 ? '+' : ''}${quote.change}%',
                    style: TextStyle(
                        color: quote.change > 0
                            ? AppColors.success
                            : AppColors.danger,
                        fontSize: 10))
              ]))
        ]),
      );
}

class _FeedCard extends StatelessWidget {
  const _FeedCard(
      {required this.initials,
      required this.color,
      required this.title,
      required this.body,
      required this.tag,
      this.likes = '0',
      this.avatar = ''});
  final String initials, title, body, tag, likes;

  /// The author's picture, "" when they have none.
  final String avatar;
  final Color color;

  factory _FeedCard.fromPost(SocialPost p) => _FeedCard(
        initials: p.authorId.length >= 2
            ? p.authorId.substring(0, 2).toUpperCase()
            : 'OC',
        color: AppColors.primary,
        title: p.authorName.isNotEmpty
            ? p.authorName
            : '@${p.authorId.length >= 8 ? p.authorId.substring(0, 8) : p.authorId}',
        body: p.body,
        tag: p.tags.isEmpty ? 'POST' : p.tags.first.toUpperCase(),
        likes: '${p.likes}',
        avatar: p.authorAvatar,
      );

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: AppSurfaces.cardDecoration(context),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AppAvatar(initials, color: color, avatar: avatar),
          const SizedBox(width: 13),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Expanded(
                      child: Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w800))),
                  StatusTag(tag, color)
                ]),
                const SizedBox(height: 9),
                Text(body, style: const TextStyle(height: 1.5)),
                const SizedBox(height: 12),
                Row(children: [
                  Icon(Icons.favorite_border_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 18),
                  const SizedBox(width: 5),
                  Text(likes,
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 18),
                  Icon(Icons.chat_bubble_outline_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 17),
                ])
              ]))
        ]),
      );
}

class _AgentRow extends StatelessWidget {
  const _AgentRow(this.name, this.status, this.color);
  final String name, status;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(Icons.smart_toy_rounded, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
            child: Text(name,
                style: const TextStyle(fontWeight: FontWeight.w600))),
        Text(status, style: TextStyle(color: color, fontSize: 11))
      ]));
}
