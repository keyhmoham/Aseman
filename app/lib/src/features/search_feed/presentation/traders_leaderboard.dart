import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_shape.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../domain/trader.dart';
import 'search_feed_view_model.dart';

/// The Traders tab: traders ranked by the reliability scores the admins
/// space's evaluator measured from their CoinMarketCap posts against market
/// data. A board picker ranks on another score; a trader opens their full
/// report.
List<Widget> traderLeaderboardSlivers(
    BuildContext context, SearchFeedViewModel model, double horizontalPad) {
  final traders = model.searchTraders(model.traders);
  final ranked =
      traders.where((t) => t.scores.of(model.board) != null).toList();
  final pending =
      traders.where((t) => t.scores.of(model.board) == null).toList();
  void open(Trader t) => showTraderReport(context, model, t);
  final pad = EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, 12);
  return [
    SliverPadding(
        padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 10),
        sliver: SliverToBoxAdapter(
            child: _Header(model: model, shown: traders.length))),
    SliverPadding(
        padding: pad,
        sliver: SliverToBoxAdapter(
            child:
                _BoardPicker(selected: model.board, onSelect: model.setBoard))),
    if (model.tradersLoading && model.traders.isEmpty)
      const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
              child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.5))))
    else if (model.tradersError != null)
      SliverFillRemaining(
          hasScrollBody: false,
          child: _Notice(
              icon: Icons.leaderboard_outlined,
              title: 'Leaderboard unavailable',
              message: model.tradersError!,
              onRetry: model.loadTraders))
    else if (traders.isEmpty)
      SliverFillRemaining(
          hasScrollBody: false,
          child: _Notice(
              icon: Icons.person_search_rounded,
              title: model.query.trim().isEmpty
                  ? 'No traders yet'
                  : 'No matching traders',
              message: model.query.trim().isEmpty
                  ? 'Administrators add traders by their CoinMarketCap profile link; they appear here once evaluated.'
                  : 'Try another name, handle or rating.'))
    else ...[
      if (ranked.isNotEmpty)
        SliverPadding(
            padding: pad,
            sliver: SliverToBoxAdapter(
                child: _Podium(
                    traders: ranked.take(3).toList(),
                    board: model.board,
                    onOpen: open))),
      if (ranked.length > 3)
        SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, 4),
            sliver: SliverList.builder(
                itemCount: ranked.length - 3,
                itemBuilder: (context, i) => _TraderRow(
                    position: i + 4,
                    trader: ranked[i + 3],
                    board: model.board,
                    onOpen: open))),
      if (pending.isNotEmpty) ...[
        SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPad, 14, horizontalPad, 8),
            sliver: SliverToBoxAdapter(
                child: Text('Awaiting evaluation',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant)))),
        SliverPadding(
            padding: EdgeInsets.fromLTRB(horizontalPad, 0, horizontalPad, 4),
            sliver: SliverList.builder(
                itemCount: pending.length,
                itemBuilder: (context, i) => _TraderRow(
                    trader: pending[i], board: model.board, onOpen: open))),
      ],
      SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontalPad, 10, horizontalPad, 32),
          sliver: const SliverToBoxAdapter(child: _Methodology())),
    ],
  ];
}

/// Opens a trader's full reliability report.
Future<void> showTraderReport(
        BuildContext context, SearchFeedViewModel model, Trader trader) =>
    showAdaptivePanel<void>(context,
        _ReportPanel(model: model, trader: trader, board: model.board));

String _score(double? v) => v == null ? '—' : v.toStringAsFixed(1);

String _compact(int? n) {
  if (n == null) return '—';
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

String _ago(DateTime? t) {
  if (t == null) return 'not yet';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

class _Header extends StatelessWidget {
  const _Header({required this.model, required this.shown});
  final SearchFeedViewModel model;
  final int shown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = model.query.trim();
    final subtitle = q.isNotEmpty
        ? '$shown trader${shown == 1 ? '' : 's'} for “$q”'
        : '${model.tradersEvaluated} of ${model.tradersTotal} evaluated · updated ${_ago(model.tradersUpdatedAt)}';
    return Row(children: [
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Traders leaderboard',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        Text('Ranked by verified reliability · $subtitle',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
      ])),
      if (model.tradersLoading && model.traders.isNotEmpty)
        const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)))
      else
        IconButton(
            tooltip: 'Refresh leaderboard',
            onPressed: model.loadTraders,
            icon: const Icon(Icons.refresh_rounded, size: 20)),
    ]);
  }
}

class _BoardPicker extends StatelessWidget {
  const _BoardPicker({required this.selected, required this.onSelect});
  final TraderBoard selected;
  final ValueChanged<TraderBoard> onSelect;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final b in TraderBoard.values)
          Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                  key: ValueKey('board-${b.api}'),
                  avatar: Icon(b.icon, size: 15),
                  label: Text(b.label),
                  showCheckmark: false,
                  selected: b == selected,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => onSelect(b))),
      ]));
}

/// A rating as a small colored pill.
class _RatingPill extends StatelessWidget {
  const _RatingPill(this.rating, {this.large = false});
  final String rating;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final color = Trader.ratingColor(rating);
    return Container(
        padding: EdgeInsets.symmetric(
            horizontal: large ? 10 : 7, vertical: large ? 5 : 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: .35))),
        child: Text(rating,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: large ? 11 : 9,
                fontWeight: FontWeight.w800,
                color: color)));
  }
}

class _TraderAvatar extends StatelessWidget {
  const _TraderAvatar(this.trader, {this.radius = 20});
  final Trader trader;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = trader.avatarUrl;
    if (url == null || !url.startsWith('http')) {
      return AppAvatar(trader.initials, color: trader.color, radius: radius);
    }
    return CircleAvatar(
        radius: radius,
        backgroundColor: trader.color.withValues(alpha: .18),
        foregroundImage: NetworkImage(url),
        onForegroundImageError: (_, __) {},
        child: Text(trader.initials,
            style: TextStyle(
                color: trader.color,
                fontWeight: FontWeight.w800,
                fontSize: 12)));
  }
}

/// A 0-100 score as a ring with the number inside.
class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score, this.size = 56, this.label});
  final double? score;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = Trader.scoreColor(score);
    return SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox.expand(
              child: CircularProgressIndicator(
                  value: (score ?? 0) / 100,
                  strokeWidth: size / 11,
                  strokeCap: StrokeCap.round,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: color)),
          Padding(
              padding: EdgeInsets.all(size / 6),
              child: FittedBox(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_score(score),
                    style: TextStyle(
                        fontSize: size / 3.6,
                        height: 1.1,
                        fontWeight: FontWeight.w900,
                        color: color)),
                if (label != null)
                  Text(label!,
                      style: TextStyle(
                          fontSize: size / 8.5,
                          height: 1.1,
                          color: scheme.onSurfaceVariant)),
              ]))),
        ]));
  }
}

/// A labelled 0-100 bar.
class _ScoreBar extends StatelessWidget {
  const _ScoreBar(
      {required this.label, required this.score, this.dense = false});
  final String label;
  final double? score;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = Trader.scoreColor(score);
    return Row(children: [
      SizedBox(
          width: dense ? 30 : 104,
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: dense ? 9 : 12, color: scheme.onSurfaceVariant))),
      Expanded(
          child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  value: (score ?? 0) / 100,
                  minHeight: dense ? 4 : 7,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: color))),
      SizedBox(
          width: dense ? 30 : 42,
          child: Text(_score(score),
              textAlign: TextAlign.end,
              style: TextStyle(
                  fontSize: dense ? 9 : 12, fontWeight: FontWeight.w800))),
    ]);
  }
}

class _Change extends StatelessWidget {
  const _Change(this.change);
  final double? change;

  @override
  Widget build(BuildContext context) {
    final c = change;
    if (c == null || c == 0) return const SizedBox.shrink();
    final up = c > 0;
    final color = up ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(up ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded,
          size: 18, color: color),
      Text(c.abs().toStringAsFixed(1),
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w800, color: color)),
    ]);
  }
}

class _Podium extends StatelessWidget {
  const _Podium(
      {required this.traders, required this.board, required this.onOpen});
  final List<Trader> traders;
  final TraderBoard board;
  final ValueChanged<Trader> onOpen;

  static const _medals = [
    Color(0xFFFFC857),
    Color(0xFFB0BEC5),
    Color(0xFFD8A47A)
  ];

  @override
  Widget build(BuildContext context) {
    Widget card(int i) => _PodiumCard(
        place: i + 1,
        medal: _medals[i],
        trader: traders[i],
        board: board,
        featured: i == 0,
        onTap: () => onOpen(traders[i]));
    // Classic podium order: 2nd, 1st, 3rd.
    final order =
        switch (traders.length) { 3 => [1, 0, 2], 2 => [0, 1], _ => [0] };
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (final (n, i) in order.indexed) ...[
        if (n > 0) const SizedBox(width: 10),
        Expanded(child: card(i)),
      ],
    ]);
  }
}

class _PodiumCard extends StatelessWidget {
  const _PodiumCard({
    required this.place,
    required this.medal,
    required this.trader,
    required this.board,
    required this.onTap,
    this.featured = false,
  });

  final int place;
  final Color medal;
  final Trader trader;
  final TraderBoard board;
  final VoidCallback onTap;
  final bool featured;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
        color: Colors.transparent,
        child: InkWell(
            key: ValueKey('trader-${trader.handle}'),
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Ink(
                padding: EdgeInsets.all(featured ? 14 : 11),
                decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          medal.withValues(alpha: .2),
                          scheme.surfaceContainerLow.withValues(alpha: .9)
                        ]),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: medal.withValues(alpha: .5))),
                child: Column(children: [
                  Row(children: [
                    Icon(
                        featured
                            ? Icons.emoji_events_rounded
                            : Icons.military_tech_rounded,
                        size: 15,
                        color: medal),
                    const SizedBox(width: 3),
                    Text('#$place',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: medal)),
                    const Spacer(),
                    _Change(trader.change),
                  ]),
                  const SizedBox(height: 8),
                  _TraderAvatar(trader, radius: featured ? 26 : 20),
                  const SizedBox(height: 7),
                  Text(trader.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w800)),
                  Text('@${trader.handle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 9, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  _ScoreRing(
                      score: trader.scores.of(board),
                      size: featured ? 64 : 52,
                      label: board.label),
                  const SizedBox(height: 8),
                  _RatingPill(trader.rating),
                  const SizedBox(height: 4),
                  Text('confidence ${_score(trader.scores.confidence)}%',
                      style: TextStyle(
                          fontSize: 8.5, color: scheme.onSurfaceVariant)),
                ]))));
  }
}

class _TraderRow extends StatelessWidget {
  const _TraderRow(
      {required this.trader,
      required this.board,
      required this.onOpen,
      this.position});
  final Trader trader;
  final TraderBoard board;
  final ValueChanged<Trader> onOpen;
  final int? position;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final score = trader.scores.of(board);
    final pendingLabel = switch (trader.status) {
      'running' => 'Evaluating…',
      'error' => 'Evaluation failed',
      _ => 'Queued',
    };
    return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
            color: scheme.surfaceContainerLow.withValues(alpha: .9),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppShape.card - 2),
                side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: .55))),
            child: InkWell(
                key: ValueKey('trader-${trader.handle}'),
                borderRadius: BorderRadius.circular(AppShape.card - 2),
                onTap: () => onOpen(trader),
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      SizedBox(
                          width: 32,
                          child: Center(
                              child: Text(position == null ? '–' : '#$position',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w900)))),
                      _TraderAvatar(trader),
                      const SizedBox(width: 11),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(trader.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text(
                                '@${trader.handle} · ${_compact(trader.followers)} followers'
                                '${trader.postsAnalyzed == null ? '' : ' · ${trader.postsAnalyzed} posts'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onSurfaceVariant)),
                            const SizedBox(height: 7),
                            if (score != null) ...[
                              Row(children: [
                                Flexible(child: _RatingPill(trader.rating)),
                                const SizedBox(width: 6),
                                Text(
                                    'conf. ${_score(trader.scores.confidence)}%',
                                    style: TextStyle(
                                        fontSize: 9,
                                        color: scheme.onSurfaceVariant)),
                              ]),
                              const SizedBox(height: 6),
                              _ScoreBar(
                                  label: 'Tech',
                                  score: trader.scores.technical,
                                  dense: true),
                              const SizedBox(height: 3),
                              _ScoreBar(
                                  label: 'Fund',
                                  score: trader.scores.fundamental,
                                  dense: true),
                            ] else
                              Text(
                                  trader.status == 'error'
                                      ? (trader.lastError ?? pendingLabel)
                                      : pendingLabel,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: trader.status == 'error'
                                          ? scheme.error
                                          : scheme.primary)),
                          ])),
                      const SizedBox(width: 10),
                      if (score != null)
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(_score(score),
                                  style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                      color: Trader.scoreColor(score))),
                              Text(board.label,
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: scheme.onSurfaceVariant)),
                              _Change(trader.change),
                            ])
                      else if (trader.status == 'running')
                        const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        Icon(
                            trader.status == 'error'
                                ? Icons.error_outline_rounded
                                : Icons.hourglass_empty_rounded,
                            size: 18,
                            color: trader.status == 'error'
                                ? scheme.error
                                : scheme.onSurfaceVariant),
                    ])))));
  }
}

class _Methodology extends StatelessWidget {
  const _Methodology();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.info_outline_rounded,
          size: 14, color: scheme.onSurfaceVariant),
      const SizedBox(width: 6),
      Expanded(
          child: Text(
              'Scores come from the Tradera evaluator: it reads each trader\'s CoinMarketCap posts, '
              'measures their calls against real market data and rates analytical performance, not writing. '
              'Confidence falls when data is thin.',
              style: TextStyle(
                  fontSize: 10, height: 1.4, color: scheme.onSurfaceVariant))),
    ]);
  }
}

class _Notice extends StatelessWidget {
  const _Notice(
      {required this.icon,
      required this.title,
      required this.message,
      this.onRetry});
  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 72,
                  height: 72,
                  decoration: ShapeDecoration(
                      color: scheme.secondaryContainer,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24))),
                  child:
                      Icon(icon, size: 34, color: scheme.onSecondaryContainer)),
              const SizedBox(height: 14),
              Text(title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(message,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again')),
              ],
            ])));
  }
}

// ── the report ────────────────────────────────────────────────────────────

class _ReportPanel extends StatefulWidget {
  const _ReportPanel(
      {required this.model, required this.trader, required this.board});
  final SearchFeedViewModel model;
  final Trader trader;
  final TraderBoard board;

  @override
  State<_ReportPanel> createState() => _ReportPanelState();
}

class _ReportPanelState extends State<_ReportPanel> {
  late Future<TraderReport?> report =
      widget.model.traderReport(widget.trader.handle);

  @override
  Widget build(BuildContext context) => FutureBuilder<TraderReport?>(
      future: report,
      builder: (context, snap) {
        final full = snap.data;
        final trader = full?.trader ?? widget.trader;
        return ListView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            children: [
              _ReportHeader(trader: trader, bio: full?.bio),
              if (widget.model.isAdmin) ...[
                const SizedBox(height: 10),
                _AdminActions(model: widget.model, trader: trader),
              ],
              const SizedBox(height: 18),
              _ScoreOverview(
                  trader: trader, history: full?.history ?? const []),
              if (snap.connectionState == ConnectionState.waiting)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: SizedBox(
                            width: 22,
                            height: 22,
                            child:
                                CircularProgressIndicator(strokeWidth: 2.5))))
              else if (snap.hasError)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                        'The full report could not be loaded: ${snap.error}',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12)))
              else if (full != null) ...[
                _Findings(
                    title: 'Strengths',
                    icon: Icons.thumb_up_alt_rounded,
                    color: const Color(0xFF22C55E),
                    items: full.strengths),
                _Findings(
                    title: 'Weaknesses',
                    icon: Icons.thumb_down_alt_rounded,
                    color: const Color(0xFFF97316),
                    items: full.weaknesses),
                _Findings(
                    title: 'Warnings',
                    icon: Icons.warning_amber_rounded,
                    color: const Color(0xFFEF4444),
                    items: full.warnings),
                for (final section in full.sections.entries)
                  _Section(title: section.key, lines: section.value),
                const SizedBox(height: 14),
                Text(
                    'Evaluated ${_ago(trader.lastEvaluatedAt)}'
                    '${trader.postsAnalyzed == null ? '' : ' from ${trader.postsAnalyzed} posts'}'
                    '${full.analysedBy == null ? '' : ' · analysed by ${full.analysedBy!.startsWith('endpoint:') ? full.analysedBy!.substring(9) : 'the Tradera agent'}'}',
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ]);
      });
}

class _ReportHeader extends StatelessWidget {
  const _ReportHeader({required this.trader, this.bio});
  final Trader trader;
  final String? bio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final link = trader.profileLink;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _TraderAvatar(trader, radius: 28),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(trader.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
          Text('@${trader.handle} · ${_compact(trader.followers)} followers',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Row(children: [
            Flexible(child: _RatingPill(trader.rating, large: true)),
            if (trader.rank != null) ...[
              const SizedBox(width: 8),
              Text('#${trader.rank} overall',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: scheme.primary)),
            ],
          ]),
        ])),
        IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close_rounded)),
      ]),
      if (bio != null && bio!.trim().isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(bio!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
      if (link != null) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(
            onPressed: () => launchUrl(Uri.parse(link),
                mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('CoinMarketCap profile')),
      ],
      if (trader.platformHandle != null) ...[
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.person_outline_rounded,
              size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
              child: Text(
                  '@${trader.platformHandle} on Tradera · their latest posts are published there',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
        ]),
      ],
    ]);
  }
}

/// Admin: the trader's Tradera account credentials, and removing the trader.
class _AdminActions extends StatelessWidget {
  const _AdminActions({required this.model, required this.trader});
  final SearchFeedViewModel model;
  final Trader trader;

  Future<void> _credentials(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final creds = await model.traderCredentials(trader.handle);
      if (!context.mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Tradera account'),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Credential(
                          label: 'Username',
                          value: '${creds['username'] ?? ''}'),
                      const SizedBox(height: 10),
                      _Credential(
                          label: 'Password',
                          value: '${creds['password'] ?? ''}'),
                      const SizedBox(height: 12),
                      Text(
                          'The evaluator signs in with this account each round to publish the trader\'s latest CoinMarketCap posts.',
                          style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close')),
                ],
              ));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(_message(e))));
    }
  }

  Future<void> _remove(BuildContext context) async {
    var deleteAccount = true;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
                  title: Text('Remove ${trader.name}?'),
                  content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                            'They leave the leaderboard and their scores are deleted.'),
                        if (trader.platformHandle != null)
                          CheckboxListTile(
                              key: const ValueKey('remove-delete-account'),
                              contentPadding: EdgeInsets.zero,
                              value: deleteAccount,
                              onChanged: (v) =>
                                  setState(() => deleteAccount = v ?? true),
                              title: Text(
                                  'Also delete @${trader.platformHandle} and the posts published there')),
                      ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel')),
                    FilledButton(
                        key: const ValueKey('remove-confirm'),
                        style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.error),
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Remove')),
                  ],
                )));
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    try {
      await model.removeTrader(trader.handle, keepAccount: !deleteAccount);
      unawaited(navigator.maybePop());
      messenger
          ?.showSnackBar(SnackBar(content: Text('${trader.name} was removed')));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(_message(e))));
    }
  }

  static String _message(Object e) =>
      e is ApiException ? e.message : e.toString();

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
            key: const ValueKey('trader-credentials'),
            onPressed: () => _credentials(context),
            icon: const Icon(Icons.key_rounded, size: 16),
            label: const Text('Credentials')),
        OutlinedButton.icon(
            key: const ValueKey('trader-remove'),
            style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => _remove(context),
            icon: const Icon(Icons.person_remove_alt_1_rounded, size: 16),
            label: const Text('Remove trader')),
      ]);
}

class _Credential extends StatelessWidget {
  const _Credential({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      Row(children: [
        Expanded(
            child: SelectableText(value,
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w700))),
        IconButton(
            tooltip: 'Copy $label',
            onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            icon: const Icon(Icons.copy_rounded, size: 18)),
      ]),
    ]);
  }
}

class _ScoreOverview extends StatelessWidget {
  const _ScoreOverview({required this.trader, required this.history});
  final Trader trader;
  final List<TraderScorePoint> history;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = trader.scores;
    if (!trader.evaluated) {
      return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppShape.card)),
          child: Text(
              trader.status == 'error'
                  ? 'The last evaluation failed: ${trader.lastError ?? 'unknown error'}'
                  : 'This trader has not been evaluated yet.',
              style: const TextStyle(fontSize: 13)));
    }
    return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppShape.card),
            border:
                Border.all(color: scheme.outlineVariant.withValues(alpha: .5))),
        child: Column(children: [
          Row(children: [
            _ScoreRing(score: s.overall, size: 92, label: 'overall'),
            const SizedBox(width: 18),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Confidence ${_score(s.confidence)}%',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                      'How much the data supports these scores: sample size, market data, clarity of the calls.',
                      style: TextStyle(
                          fontSize: 10.5, color: scheme.onSurfaceVariant)),
                  if (history.length >= 2) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                        height: 34,
                        child: CustomPaint(
                            size: Size.infinite,
                            painter: _HistoryPainter(history, scheme.primary))),
                    Text('Overall score across ${history.length} evaluations',
                        style: TextStyle(
                            fontSize: 9, color: scheme.onSurfaceVariant)),
                  ],
                ])),
          ]),
          const SizedBox(height: 16),
          for (final (label, value) in [
            ('Technical', s.technical),
            ('Fundamental', s.fundamental),
            ('Accuracy', s.accuracy),
            ('Consistency', s.consistency),
            ('Risk management', s.risk),
            ('Timing', s.timing),
          ])
            Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ScoreBar(label: label, score: value)),
        ]));
  }
}

class _HistoryPainter extends CustomPainter {
  _HistoryPainter(this.points, this.color);
  final List<TraderScorePoint> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final values = points.map((p) => p.overall).toList();
    final lo = values.reduce(math.min) - 2, hi = values.reduce(math.max) + 2;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height * (1 - (values[i] - lo) / (hi - lo));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _HistoryPainter old) =>
      old.points != points || old.color != color;
}

class _Findings extends StatelessWidget {
  const _Findings(
      {required this.title,
      required this.icon,
      required this.color,
      required this.items});
  final String title;
  final IconData icon;
  final Color color;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(title,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 8),
          for (final item in items)
            Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                          padding: const EdgeInsets.only(top: 6, right: 8),
                          child: Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                  color: color, shape: BoxShape.circle))),
                      Expanded(
                          child: Text(item,
                              style: const TextStyle(
                                  fontSize: 12.5, height: 1.35))),
                    ])),
        ]));
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.lines});
  final String title;
  final List<MapEntry<String, String>> lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Material(
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppShape.inner)),
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
                title: Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w800)),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  for (final line in lines)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                  flex: 5,
                                  child: Text(line.key,
                                      style: TextStyle(
                                          fontSize: 11.5,
                                          color: scheme.onSurfaceVariant))),
                              const SizedBox(width: 10),
                              Expanded(
                                  flex: 4,
                                  child: Text(line.value,
                                      textAlign: TextAlign.end,
                                      style: const TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700))),
                            ])),
                ])));
  }
}
