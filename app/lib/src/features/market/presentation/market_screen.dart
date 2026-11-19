import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../core/theme/aseman_tokens.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/bot_avatar.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/panel_scaffold.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';

/// Marketplace — a modal panel (dialog on desktop, bottom sheet on mobile) to
/// browse and publish agents and apps, and install agents. Uses the app's
/// TabBar panel convention.
///
/// When [embedded] is true the outer panel chrome is omitted so the Store
/// hub can host Library and Discover together.
class MarketScreen extends StatefulWidget {
  const MarketScreen({
    super.key,
    required this.dependencies,
    this.embedded = false,
  });

  final AppDependencies dependencies;
  final bool embedded;

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

/// Pagination state for one store tab. Agents and apps page independently:
/// one kind can run out while the other still has more.
class _Feed {
  List<MarketListing> items = [];
  bool hasMore = false;
  bool loadingMore = false;
  bool loadMoreFailed = false;
}

class _MarketScreenState extends State<MarketScreen> {
  static const _pageSize = 20;
  final _agents = _Feed();
  final _tools = _Feed();
  final search = TextEditingController();
  bool _loading = true;
  String? _error;
  String _query = '';

  /// Bumped on every fresh load so late "load more" responses for a previous
  /// query or refresh are discarded instead of being appended.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<List<MarketListing>> _fetch(String type, String query, int offset) =>
      widget.dependencies.service.fetchMarket(
        type: type,
        query: query,
        limit: _pageSize,
        offset: offset,
      );

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    final query = search.text.trim();
    try {
      final results = await Future.wait([
        _fetch('agent', query, 0),
        _fetch('tool', query, 0),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        for (final (feed, page) in [
          (_agents, results[0]),
          (_tools, results[1]),
        ]) {
          feed.items = _dedupe(page);
          feed.hasMore = page.length >= _pageSize;
          feed.loadingMore = false;
          feed.loadMoreFailed = false;
        }
        _query = query;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore(_Feed feed, String type) async {
    if (_loading || feed.loadingMore || !feed.hasMore) return;
    final generation = _generation;
    setState(() {
      feed.loadingMore = true;
      feed.loadMoreFailed = false;
    });
    try {
      final page = await _fetch(type, _query, feed.items.length);
      if (!mounted || generation != _generation) return;
      final known = {for (final item in feed.items) item.id};
      final fresh = _dedupe(page).where((item) => known.add(item.id)).toList();
      setState(() {
        feed.items = [...feed.items, ...fresh];
        // Stop when the server has nothing new, so a backend that ignores
        // `offset` can never make the list repeat itself forever.
        feed.hasMore = fresh.isNotEmpty && page.length >= _pageSize;
        feed.loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        feed.loadingMore = false;
        feed.loadMoreFailed = true;
      });
    }
  }

  static List<MarketListing> _dedupe(List<MarketListing> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(item.id)) item,
    ];
  }

  Future<void> _addTo(MarketListing listing) async {
    final choice = await showAdaptivePanel<_SpaceChoice>(
      context,
      _AddToDialog(
        dependencies: widget.dependencies,
        listingName: listing.name,
      ),
      maxWidth: 440,
      maxHeight: 560,
    );
    if (choice == null || !mounted) return;
    try {
      await widget.dependencies.service.installListing(
        listing.id,
        spaceId: choice.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${listing.name} added to ${choice.title}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add ${listing.name}: $e')),
      );
    }
  }

  Future<void> _openPublish() async {
    final published = await showAppForm<bool>(
      context,
      _PublishDialog(dependencies: widget.dependencies),
    );
    if (published == true) await _load();
  }

  Widget _searchField() => SoftSearchField(
    controller: search,
    dense: true,
    hintText: 'Search Decillion Store',
    onSubmitted: (_) => _load(),
    trailing: IconButton(
      onPressed: _load,
      icon: const Icon(Icons.arrow_forward_rounded),
    ),
  );

  Widget _kindTabs({required bool compact}) => SegmentedTabBar(
    compact: compact,
    alignment: Alignment.centerLeft,
    labels: const ['Agents', 'Apps'],
    icons: const [Icons.smart_toy_outlined, Icons.apps_outlined],
  );

  Widget _toolbar({required bool compact}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _searchField(),
      const SizedBox(height: AppSpacing.sm),
      _kindTabs(compact: compact),
    ],
  );

  List<Widget> get _actions => [
    FilledButton.icon(
      onPressed: _openPublish,
      icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
      label: const Text('Publish'),
    ),
    IconButton(
      tooltip: 'Refresh',
      onPressed: _load,
      icon: const Icon(Icons.refresh_rounded),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.compact;
    final body = _loading
        ? const SkeletonList(item: SkeletonCard(mediaHeight: 0), spacing: 10)
        : _error != null
        ? Center(child: Text(_error!))
        : TabBarView(
            children: [
              _ListingList(
                items: _agents.items,
                editorial: _query.isEmpty,
                hasMore: _agents.hasMore,
                loadingMore: _agents.loadingMore,
                loadMoreFailed: _agents.loadMoreFailed,
                onLoadMore: () => _loadMore(_agents, 'agent'),
                onInstall: _addTo,
              ),
              _ListingList(
                items: _tools.items,
                editorial: _query.isEmpty,
                shelfNoun: 'apps',
                hasMore: _tools.hasMore,
                loadingMore: _tools.loadingMore,
                loadMoreFailed: _tools.loadMoreFailed,
                onLoadMore: () => _loadMore(_tools, 'tool'),
                onInstall: _addTo,
              ),
            ],
          );
    return DefaultTabController(
      length: 2,
      child: widget.embedded
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: _searchField()),
                    const SizedBox(width: 8),
                    ..._actions,
                  ],
                ),
                const SizedBox(height: 6),
                _kindTabs(compact: true),
                const SizedBox(height: 6),
                Expanded(child: body),
              ],
            )
          : PanelScaffold(
              compact: compact,
              header: PanelHeader(
                icon: Icons.storefront_outlined,
                title: 'Market',
                subtitle: 'Discover agents and apps on Decillion',
                onClose: () => Navigator.pop(context),
                actions: _actions,
              ),
              toolbar: _toolbar(compact: compact),
              body: body,
            ),
    );
  }
}

class _ListingList extends StatefulWidget {
  const _ListingList({
    required this.items,
    this.onInstall,
    this.editorial = false,
    this.shelfNoun = 'agents',
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.onLoadMore,
  });

  final List<MarketListing> items;

  /// Opens the space picker. Set for both agents and apps.
  final ValueChanged<MarketListing>? onInstall;

  /// Browse layout (spotlight + charts). Search results stay a flat catalog.
  final bool editorial;
  final String shelfNoun;
  final bool hasMore;
  final bool loadingMore;
  final bool loadMoreFailed;
  final VoidCallback? onLoadMore;

  @override
  State<_ListingList> createState() => _ListingListState();
}

class _ListingListState extends State<_ListingList> {
  final _scroll = ScrollController();
  String? _category;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A short first page (or a category filter) can leave the list too short
  /// to scroll, so no scroll event would ever ask for the next page. Keep
  /// loading until the viewport is filled or the feed is exhausted.
  void _fillViewport() {
    if (!mounted ||
        !widget.hasMore ||
        widget.loadingMore ||
        widget.loadMoreFailed ||
        !_scroll.hasClients) {
      return;
    }
    if (_scroll.position.extentAfter < 250) widget.onLoadMore?.call();
  }

  List<String> get _categories {
    final seen = <String>{};
    for (final item in widget.items) {
      final category = item.category.trim();
      if (category.isNotEmpty) seen.add(category);
    }
    final list = seen.toList()..sort();
    return list;
  }

  List<MarketListing> get _visible {
    final category = _category;
    if (category == null) return widget.items;
    return [
      for (final item in widget.items)
        if (item.category.trim() == category) item,
    ];
  }

  @override
  void didUpdateWidget(covariant _ListingList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_category != null && !_categories.contains(_category)) {
      _category = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fillViewport());
  }

  @override
  Widget build(BuildContext context) {
    final items = _visible;
    if (widget.items.isEmpty) {
      final apps = widget.shelfNoun == 'apps';
      return PanelEmpty(
        icon: apps ? Icons.apps_outlined : Icons.smart_toy_outlined,
        title: 'Nothing published here yet',
        message: apps
            ? 'Apps appear here when creators publish them.'
            : 'Browse agents, then add one to a workspace or a direct chat.',
      );
    }
    final editorial = widget.editorial && _category == null && items.isNotEmpty;
    final railCount = editorial ? (items.length - 1).clamp(0, 8) : 0;
    final gridStart = editorial ? 1 + railCount : 0;
    // Re-check after every build: covers the list being too short to scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fillViewport());
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // Only the main vertical list may page; the horizontal chart and
        // category rails also bubble up here and ended up triggering loads.
        if (n.depth == 0 &&
            n.metrics.axis == Axis.vertical &&
            n is! ScrollMetricsNotification &&
            widget.hasMore &&
            !widget.loadingMore &&
            !widget.loadMoreFailed &&
            n.metrics.extentAfter < 250) {
          widget.onLoadMore?.call();
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth.isFinite ? box.maxWidth : 600.0;
          final columns = (width / 340).floor().clamp(1, 3);
          final gap = 12.0;
          final tileWidth = columns == 1
              ? width
              : (width - (columns - 1) * gap) / columns;
          return ListView(
            controller: _scroll,
            padding: const EdgeInsets.only(top: 4, bottom: 18),
            children: [
              if (_categories.isNotEmpty) ...[
                _CategoryRail(
                  categories: _categories,
                  selected: _category,
                  onSelected: (value) => setState(() => _category = value),
                ),
                const SizedBox(height: 12),
              ],
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Text(
                    'Nothing in this category.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else ...[
                if (editorial) ...[
                  _Spotlight(
                    listing: items.first,
                    wide: width >= 560,
                    onInstall: widget.onInstall == null
                        ? null
                        : () => widget.onInstall!(items.first),
                  ),
                  if (railCount > 0) ...[
                    const SizedBox(height: 18),
                    _ShelfLabel(
                      'Top charts',
                      trailing: '${items.length} ${widget.shelfNoun}',
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 176,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: railCount,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (context, i) {
                          final listing = items[i + 1];
                          return SizedBox(
                            width: 132,
                            child: _ChartTile(
                              rank: i + 2,
                              listing: listing,
                              onInstall: widget.onInstall == null
                                  ? null
                                  : () => widget.onInstall!(listing),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
                if (gridStart < items.length) ...[
                  if (editorial) ...[
                    const SizedBox(height: 18),
                    _ShelfLabel(
                      railCount > 0
                          ? 'More to explore'
                          : 'All ${widget.shelfNoun}',
                    ),
                    const SizedBox(height: 8),
                  ],
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (var i = gridStart; i < items.length; i++)
                        SizedBox(
                          width: tileWidth,
                          child: _StoreRow(
                            listing: items[i],
                            onInstall: widget.onInstall == null
                                ? null
                                : () => widget.onInstall!(items[i]),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
              if (widget.loadMoreFailed) ...[
                const SizedBox(height: 12),
                Center(
                  child: TextButton.icon(
                    onPressed: widget.onLoadMore,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Couldn\'t load more. Tap to retry'),
                  ),
                ),
              ] else if (widget.hasMore || widget.loadingMore) ...[
                const SizedBox(height: 12),
                const SkeletonCard(mediaHeight: 0),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('All'),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final category in categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(category),
                selected: selected == category,
                onSelected: (_) =>
                    onSelected(selected == category ? null : category),
              ),
            ),
        ],
      ),
    );
  }
}

class _ShelfLabel extends StatelessWidget {
  const _ShelfLabel(this.title, {this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -.2,
            ),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

class _Spotlight extends StatelessWidget {
  const _Spotlight({required this.listing, required this.wide, this.onInstall});

  final MarketListing listing;
  final bool wide;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EyebrowLabel('FEATURED'),
        const SizedBox(height: 6),
        Text(
          listing.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -.6,
            height: 1.05,
          ),
        ),
        if (listing.description.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            listing.description,
            maxLines: wide ? 3 : 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            SoftMetaChip(
              label: listing.kindLabel.toUpperCase(),
              accent: listing.isApp
                  ? AppColors.cyanOf(context)
                  : AppColors.primaryOf(context),
            ),
            if (listing.category.isNotEmpty)
              SoftMetaChip(
                label: listing.category,
                accent: scheme.onSurfaceVariant,
              ),
            SoftMetaChip(
              icon: Icons.download_rounded,
              label: '${listing.installs}',
              accent: scheme.onSurfaceVariant,
            ),
            SoftMetaChip(
              icon: Icons.stars_rounded,
              label: _priceLabel(listing),
              accent: listing.price == 0
                  ? AppColors.successOf(context)
                  : scheme.primary,
            ),
          ],
        ),
        if (onInstall != null) ...[
          const SizedBox(height: 14),
          FilledButton(onPressed: onInstall, child: const Text('Add to')),
        ],
      ],
    );
    final art = _ListingArt(listing: listing, radius: wide ? 36 : 28);
    return SoftCard(
      wash: true,
      elevated: true,
      radius: AppShape.card,
      padding: EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer.withValues(alpha: dark ? .72 : .9),
              Color.alphaBlend(
                scheme.tertiaryContainer.withValues(alpha: dark ? .45 : .55),
                scheme.surface,
              ),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: wide
              ? Row(
                  children: [
                    art,
                    const SizedBox(width: 18),
                    Expanded(child: copy),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [art, const SizedBox(height: 14), copy],
                ),
        ),
      ),
    );
  }
}

class _ChartTile extends StatelessWidget {
  const _ChartTile({required this.rank, required this.listing, this.onInstall});

  final int rank;
  final MarketListing listing;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$rank',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                  height: 1,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _priceLabel(listing),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: listing.price == 0
                        ? AppColors.successOf(context)
                        : scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _ListingArt(listing: listing, radius: 18),
          const SizedBox(height: 8),
          Text(
            listing.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              letterSpacing: -.2,
            ),
          ),
          Text(
            listing.category.isEmpty ? listing.kindLabel : listing.category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          if (onInstall != null)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: onInstall,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 30),
                ),
                child: const Text('Add to'),
              ),
            ),
        ],
      ),
    );
  }
}

class _StoreRow extends StatelessWidget {
  const _StoreRow({required this.listing, this.onInstall});

  final MarketListing listing;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = [
      if (listing.category.isNotEmpty) listing.category else listing.kindLabel,
      '${listing.installs} installs',
    ].join(' · ');
    return SoftCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _ListingArt(listing: listing, radius: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  listing.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                    letterSpacing: -.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (listing.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    listing.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _priceLabel(listing),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: listing.price == 0
                      ? AppColors.successOf(context)
                      : scheme.onSurface,
                ),
              ),
              if (onInstall != null) ...[
                const SizedBox(height: 6),
                FilledButton.tonal(
                  onPressed: onInstall,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('Add to'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ListingArt extends StatelessWidget {
  const _ListingArt({required this.listing, required this.radius});

  final MarketListing listing;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return BotAvatar(
      bot:
          listing.bot ??
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
      radius: radius,
    );
  }
}

String _priceLabel(MarketListing listing) =>
    listing.price == 0 ? 'Free' : formatLedgerCredits(listing.price);

/// A workspace or a direct-chat space the caller can add a listing into.
class _SpaceChoice {
  const _SpaceChoice({
    required this.id,
    required this.title,
    required this.direct,
  });

  final String id;
  final String title;
  final bool direct;
}

class _AddToDialog extends StatefulWidget {
  const _AddToDialog({required this.dependencies, required this.listingName});

  final AppDependencies dependencies;
  final String listingName;

  @override
  State<_AddToDialog> createState() => _AddToDialogState();
}

class _AddToDialogState extends State<_AddToDialog> {
  List<_SpaceChoice> _workspaces = const [];
  List<_SpaceChoice> _directs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.dependencies.service.fetchSpaces(),
        widget.dependencies.service.fetchChats(),
      ]);
      if (!mounted) return;
      final spaces = results[0] as List<Workspace>;
      final chats = results[1] as List<ChatSummary>;
      final seenDirect = <String>{};
      setState(() {
        _workspaces = [
          for (final space in spaces)
            if (space.id.isNotEmpty && space.spaceKind != 'direct')
              _SpaceChoice(
                id: space.id,
                title: space.name.isEmpty ? 'Workspace' : space.name,
                direct: false,
              ),
        ];
        _directs = [
          for (final chat in chats)
            if (chat.direct &&
                chat.spaceId.isNotEmpty &&
                seenDirect.add(chat.spaceId))
              _SpaceChoice(id: chat.spaceId, title: chat.title, direct: true),
        ];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Add to a space',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.3,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                'Choose where ${widget.listingName} should live — a workspace or a direct chat.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: _body(scheme)),
          ],
        ),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading) {
      return const SkeletonList(itemCount: 4);
    }
    if (_error != null) {
      return PanelEmpty(
        icon: Icons.error_outline_rounded,
        title: 'Could not load spaces',
        message: _error!,
      );
    }
    if (_workspaces.isEmpty && _directs.isEmpty) {
      return const PanelEmpty(
        icon: Icons.workspaces_outlined,
        title: 'No spaces yet',
        message:
            'Create a workspace or open a direct chat, then add from here.',
      );
    }
    return ListView(
      children: [
        if (_workspaces.isNotEmpty) ...[
          const _ShelfLabel('Workspaces'),
          const SizedBox(height: 4),
          for (final space in _workspaces) _choiceTile(space, scheme),
        ],
        if (_directs.isNotEmpty) ...[
          if (_workspaces.isNotEmpty) const SizedBox(height: 12),
          const _ShelfLabel('Direct chats'),
          const SizedBox(height: 4),
          for (final chat in _directs) _choiceTile(chat, scheme),
        ],
      ],
    );
  }

  Widget _choiceTile(_SpaceChoice choice, ColorScheme scheme) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        choice.direct ? Icons.forum_rounded : Icons.workspaces_rounded,
        color: scheme.primary,
      ),
      title: Text(
        choice.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(choice.direct ? 'Direct chat' : 'Workspace'),
      onTap: () => Navigator.pop(context, choice),
    );
  }
}

/// Dialog that lets the user publish one of their bots to the marketplace.
class _PublishDialog extends StatefulWidget {
  const _PublishDialog({required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  List<Bot> _bots = [];
  bool _loading = true;
  String _type = 'agent';
  Bot? _selected;
  final nameController = TextEditingController();
  final descController = TextEditingController();
  double _price = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    nameController.dispose();
    descController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bots = await widget.dependencies.service.fetchBots();
      setState(() {
        _bots = bots;
        final agents = bots.where((b) => b.kind == _type);
        _selected = agents.isNotEmpty
            ? agents.first
            : bots.isEmpty
            ? null
            : bots.first;
        if (_selected?.isTool ?? false) _type = 'tool';
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final bot = _selected;
    if (bot == null) return;
    final price = creditsToLedger(_price);
    try {
      await widget.dependencies.service.publishListing(
        botId: bot.id,
        type: _type,
        name: nameController.text.trim().isEmpty
            ? bot.name
            : nameController.text.trim(),
        description: descController.text.trim(),
        price: price,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Publish failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _bots.where((b) => b.kind == _type).toList();
    return AppFormFrame(
      icon: Icons.storefront_outlined,
      title: 'Publish to the market',
      subtitle: 'Pick one of your bots and set how it is listed.',
      submit: 'Publish',
      onSubmit: _loading || _selected == null ? null : _submit,
      children: [
        if (_loading)
          const SkeletonField()
        else if (_bots.isEmpty)
          Text(
            'You have no bots yet. Create an agent or app first.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          )
        else ...[
          AppSegmentedField<String>(
            label: 'Type',
            value: _type,
            onChanged: (v) => setState(() {
              _type = v;
              final match = _bots.where((b) => b.kind == v);
              _selected = match.isEmpty ? null : match.first;
            }),
            choices: const [
              AppChoice('agent', 'Agent', icon: Icons.smart_toy_outlined),
              AppChoice('tool', 'App', icon: Icons.apps_outlined),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppFieldLabel('Bot'),
              if (shown.isEmpty)
                Text(
                  _type == 'agent'
                      ? 'You have no agents yet.'
                      : 'You have no apps yet.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              for (final b in shown)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: _selected?.id == b.id
                        ? ThemeRoles.selectedFill(context)
                        : AppSurfaces.card(
                            scheme,
                            tokens: AsemanTokens.maybeOf(context),
                          ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        AppShape.controlOf(context),
                      ),
                      side: BorderSide(
                        color: _selected?.id == b.id
                            ? scheme.primary.withValues(alpha: .35)
                            : AppSurfaces.cardBorder(scheme),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      onTap: () => setState(() => _selected = b),
                      leading: BotAvatar(
                        bot: b,
                        radius: 20,
                        userId:
                            widget
                                .dependencies
                                .sessionController
                                .session
                                ?.accountId ??
                            '',
                      ),
                      title: Text(
                        b.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text('${b.kindLabel} · ${b.status}'),
                      trailing: _selected?.id == b.id
                          ? Icon(
                              Icons.check_circle_rounded,
                              color: scheme.primary,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          TextField(
            controller: nameController,
            decoration: InputDecoration(
              labelText: 'Listing title',
              hintText: _selected?.name,
              helperText: 'Leave empty to use the bot’s name.',
            ),
          ),
          TextField(
            controller: descController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Description',
              alignLabelWithHint: true,
            ),
          ),
          AppAmountField(
            label: 'Price',
            hint: _price == 0
                ? 'Free to add; usage is still billed.'
                : '≈ ${formatLedgerUsd(creditsToLedger(_price))}',
            value: _price,
            max: 5000,
            step: 10,
            decimals: 0,
            unit: 'credits',
            presets: const [0, 50, 100, 500, 1000],
            presetLabel: (v) => v == 0 ? 'Free' : compactDecimal(v),
            format: (v) => v == 0 ? 'Free' : '${compactDecimal(v)} credits',
            onChanged: (v) => setState(() => _price = v),
          ),
        ],
      ],
    );
  }
}
