import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/status_tag.dart';

/// Marketplace — a modal panel (dialog on desktop, bottom sheet on mobile) to
/// browse, install and publish agents and miniapps. Uses the app's TabBar
/// panel convention; miniapps surface as tools.
class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> {
  static const _pageSize = 20;
  List<MarketListing> _agents = [];
  List<MarketListing> _tools = [];
  final search = TextEditingController();
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _offset = 0;
  String? _error;

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

  Future<void> _load({bool more = false}) async {
    if (more) {
      if (_loadingMore || !_hasMore || _loading) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final query = search.text.trim();
    final offset = more ? _offset : 0;
    try {
      final results = await Future.wait([
        widget.dependencies.service.fetchMarket(
            type: 'agent', query: query, limit: _pageSize, offset: offset),
        widget.dependencies.service.fetchMarket(
            type: 'miniapp', query: query, limit: _pageSize, offset: offset),
      ]);
      if (!mounted) return;
      final agents = results[0];
      final tools = results[1];
      setState(() {
        if (more) {
          _agents.addAll(agents);
          _tools.addAll(tools);
          _offset += agents.length;
        } else {
          _agents = agents;
          _tools = tools;
          _offset = agents.length;
        }
        _hasMore = agents.length >= _pageSize || tools.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _install(MarketListing listing) async {
    try {
      final homeId =
          widget.dependencies.sessionController.session?.homeSpaceId ?? '';
      final botId = await widget.dependencies.service
          .installListing(listing.id, spaceId: homeId.isEmpty ? null : homeId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(botId.isNotEmpty
              ? '${listing.name} installed into your workspace'
              : 'Installed'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Install failed: $e')));
    }
  }

  Future<void> _openPublish() async {
    final published = await showDialog<bool>(
      context: context,
      builder: (context) => _PublishDialog(dependencies: widget.dependencies),
    );
    if (published == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            compact ? 16 : 26, compact ? 16 : 22, compact ? 16 : 26, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PanelHeader(
            icon: Icons.storefront_outlined,
            title: 'Market',
            subtitle: 'Publish & install agents and miniapps',
            onClose: () => Navigator.pop(context),
            actions: [
              FilledButton.icon(
                onPressed: _openPublish,
                icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                label: const Text('Publish'),
              ),
              IconButton(
                  tooltip: 'Refresh',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded)),
            ],
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: TextField(
                controller: search,
                onSubmitted: (_) => _load(),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: 'Search agents & tools…',
                  isDense: true,
                  suffixIcon: IconButton(
                    onPressed: _load,
                    icon: const Icon(Icons.arrow_forward_rounded),
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          SegmentedTabBar(
            compact: compact,
            alignment: Alignment.centerLeft,
            labels: const ['Agents', 'Tools'],
            icons: const [Icons.smart_toy_outlined, Icons.widgets_outlined],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : TabBarView(children: [
                        _ListingList(
                            items: _agents,
                            hasMore: _hasMore,
                            loadingMore: _loadingMore,
                            onLoadMore: () => _load(more: true),
                            onInstall: _install),
                        _ListingList(
                            items: _tools,
                            hasMore: _hasMore,
                            loadingMore: _loadingMore,
                            onLoadMore: () => _load(more: true),
                            onInstall: _install),
                      ]),
          ),
        ]),
      ),
    );
  }
}

class _ListingList extends StatelessWidget {
  const _ListingList(
      {required this.items,
      required this.onInstall,
      this.hasMore = false,
      this.loadingMore = false,
      this.onLoadMore});

  final List<MarketListing> items;
  final ValueChanged<MarketListing> onInstall;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.storefront_outlined,
              size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text('Nothing published here yet.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      );
    }
    return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (hasMore && !loadingMore && n.metrics.extentAfter < 250) {
            onLoadMore?.call();
          }
          return false;
        },
        child: ListView.separated(
          padding: const EdgeInsets.only(top: 4, bottom: 18),
          itemCount: items.length + (hasMore || loadingMore ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            if (i >= items.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5))),
              );
            }
            return _ListingCard(
                listing: items[i], onInstall: () => onInstall(items[i]));
          },
        ));
  }
}

class _ListingCard extends StatelessWidget {
  const _ListingCard({required this.listing, required this.onInstall});

  final MarketListing listing;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = listing.isMiniapp ? AppColors.cyan : AppColors.primary;
    final header = Row(children: [
      AppAvatar(listing.name, color: color, radius: 22),
      const SizedBox(width: 13),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(
              child: Text(listing.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 8),
            StatusTag(listing.type.toUpperCase(), color),
          ]),
        ]),
      ),
    ]);
    final meta = Row(children: [
      Icon(Icons.download_rounded, size: 13, color: scheme.onSurfaceVariant),
      const SizedBox(width: 4),
      Text('${listing.installs} installs',
          style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
      const SizedBox(width: 16),
      Icon(Icons.stars_rounded, size: 13, color: scheme.onSurfaceVariant),
      const SizedBox(width: 4),
      Text(listing.price == 0 ? 'Free' : formatLedgerCredits(listing.price),
          style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
    ]);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 460) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header,
                    if (listing.description.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(listing.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                              height: 1.4)),
                    ],
                    const SizedBox(height: 9),
                    meta,
                  ]),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
                onPressed: onInstall, child: const Text('Install')),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          header,
          if (listing.description.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(listing.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, color: scheme.onSurfaceVariant, height: 1.4)),
          ],
          const SizedBox(height: 9),
          Row(children: [
            Expanded(child: meta),
            const SizedBox(width: 10),
            FilledButton.tonal(
                onPressed: onInstall,
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                child: const Text('Install')),
          ]),
        ]);
      }),
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
  final priceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    nameController.dispose();
    descController.dispose();
    priceController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bots = await widget.dependencies.service.fetchBots();
      setState(() {
        _bots = bots;
        _selected = bots.isEmpty ? null : bots.first;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final bot = _selected;
    if (bot == null) return;
    final price = parseCreditsToLedger(priceController.text);
    if (price == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid credit price.')));
      return;
    }
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Publish failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('Publish to marketplace'),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()))
            : _bots.isEmpty
                ? const Text(
                    'You have no bots yet. Create an agent or miniapp first.')
                : SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'agent', label: Text('Agent')),
                          ButtonSegment(
                              value: 'miniapp', label: Text('Miniapp')),
                        ],
                        selected: {_type},
                        onSelectionChanged: (sel) =>
                            setState(() => _type = sel.first),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<Bot>(
                        initialValue: _selected,
                        decoration: const InputDecoration(labelText: 'Bot'),
                        items: _bots
                            .map((b) => DropdownMenuItem(
                                value: b,
                                child: Text(
                                    '${b.name} · ${b.kind} · ${b.vmType}')))
                            .toList(),
                        onChanged: (b) => setState(() => _selected = b),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                            labelText: 'Marketplace name (optional)'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: descController,
                        maxLines: 2,
                        decoration:
                            const InputDecoration(labelText: 'Description'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: priceController,
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(labelText: 'Price (credits)'),
                      ),
                    ]),
                  ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _loading || _selected == null ? null : _submit,
          child: const Text('Publish'),
        ),
      ],
    );
  }
}
