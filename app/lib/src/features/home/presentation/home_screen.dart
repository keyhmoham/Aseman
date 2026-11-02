import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/post.dart';
import '../../../data/repositories/market_repository.dart';
import '../../../domain/models/market_quote.dart';
import '../../../shared/widgets/app_panel.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/bot_avatar.dart';
import '../../../shared/widgets/page_scaffold.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/skeleton.dart';
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
        subtitle: 'Your feed, agents, and rooms at a glance',
        actions: [
          FilledButton.icon(
              onPressed: widget.openRoom,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create room'))
        ],
        child: AnimatedBuilder(
            animation: model,
            builder: (context, _) {
              if (model.loading) return const SkeletonPage();
              if (model.error != null)
                return Center(
                    child: Text('Could not load pulse data: ${model.error}'));
              return LayoutBuilder(builder: (context, constraints) {
                final feed = ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 14, 24),
                    children: [
                      Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children:
                              model.quotes.map(_MarketTile.new).toList()),
                      const SizedBox(height: 16),
                      if (_loading)
                        const SkeletonList(itemCount: 3, item: SkeletonPost())
                      else if (_feed.isEmpty)
                        const PanelEmpty(
                          icon: Icons.rss_feed_rounded,
                          title: 'No platform posts yet',
                          message:
                              'Posts from people and agents will show up here as they land.',
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
                                    title: 'Wallet balance',
                                    value: formatLedgerCredits(_balance),
                                    change: 'from finance.wallet',
                                    color: AppColors.success),
                                const SizedBox(height: 12),
                                AppPanel(
                                    title: 'Active agents',
                                    child: _bots.isEmpty
                                        ? const PanelEmpty(
                                            compact: true,
                                            icon: Icons.smart_toy_outlined,
                                            title: 'No agents yet',
                                            message:
                                                'Create one in My bots to see it here.',
                                          )
                                        : Column(
                                            children: _bots
                                                .where((b) => b.isAgent)
                                                .take(4)
                                                .map((b) => _AgentRow(
                                                    b,
                                                    b.status == 'running'
                                                        ? AppColors.success
                                                        : Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                    userId: widget
                                                            .dependencies
                                                            ?.sessionController
                                                            .session
                                                            ?.accountId ??
                                                        '',
                                                  ))
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final up = quote.change > 0;
    return SizedBox(
      width: 168,
      height: 86,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm + 2),
        decoration:
            AppSurfaces.cardDecoration(context, radius: AppShape.inner),
        child: Row(children: [
          AppAvatar(quote.symbol[0], color: quote.color),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                Text(quote.symbol,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        )),
                Text(quote.price,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        )),
                Text('${up ? '+' : ''}${quote.change}%',
                    style: TextStyle(
                        color: up ? AppColors.success : AppColors.danger,
                        fontSize: 11,
                        fontWeight: FontWeight.w700))
              ]))
        ]),
      ),
    );
  }
}

class _FeedCard extends StatelessWidget {
  const _FeedCard(
      {required this.initials,
      required this.color,
      required this.title,
      required this.body,
      required this.tag,
      this.likes = '0',
      this.avatar = '',
      this.authorId = ''});
  final String initials, title, body, tag, likes;

  /// The author's picture, "" when they have none.
  final String avatar;
  final String authorId;
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
        authorId: p.authorId,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration:
            AppSurfaces.cardDecoration(context, radius: AppShape.inner),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AppAvatar(initials,
              color: color, avatar: avatar, identity: authorId),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Expanded(
                      child: Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800))),
                  StatusTag(tag, color)
                ]),
                const SizedBox(height: AppSpacing.xs),
                Text(body,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(height: 1.45)),
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  Icon(Icons.favorite_border_rounded,
                      color: scheme.onSurfaceVariant, size: 18),
                  const SizedBox(width: 5),
                  Text(likes,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  const SizedBox(width: 18),
                  Icon(Icons.chat_bubble_outline_rounded,
                      color: scheme.onSurfaceVariant, size: 17),
                ])
              ])),
        ]),
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow(this.bot, this.color, {this.userId = ''});
  final Bot bot;
  final Color color;
  final String userId;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(children: [
        BotAvatar(bot: bot, radius: 14, userId: userId),
        const SizedBox(width: AppSpacing.sm - 2),
        Expanded(
            child: Text(bot.name,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600))),
        Text(bot.status,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w700))
      ]));
}
