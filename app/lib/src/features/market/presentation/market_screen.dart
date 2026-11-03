import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../core/theme/aseman_tokens.dart';
import '../../../data/models/bot.dart';
import '../../../shared/widgets/app_form.dart';
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
          type: 'agent',
          query: query,
          limit: _pageSize,
          offset: offset,
        ),
        widget.dependencies.service.fetchMarket(
          type: 'tool',
          query: query,
          limit: _pageSize,
          offset: offset,
        ),
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
      final botId = await widget.dependencies.service.installListing(
        listing.id,
        spaceId: homeId.isEmpty ? null : homeId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            botId.isNotEmpty
                ? '${listing.name} installed into your workspace'
                : 'Installed',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Install failed: $e')));
    }
  }

  Future<void> _openPublish() async {
    final published = await showAppForm<bool>(
      context,
      _PublishDialog(dependencies: widget.dependencies),
    );
    if (published == true) await _load();
  }

  Widget _toolbar({required bool compact}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SoftSearchField(
            controller: search,
            dense: true,
            hintText: 'Search agents & apps…',
            onSubmitted: (_) => _load(),
            trailing: IconButton(
              onPressed: _load,
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SegmentedTabBar(
            compact: compact,
            alignment: Alignment.centerLeft,
            labels: const ['Agents', 'Apps'],
            icons: const [Icons.smart_toy_outlined, Icons.apps_outlined],
          ),
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
    final compact = MediaQuery.sizeOf(context).width < 560;
    final body = _loading
        ? const SkeletonList(
            item: SkeletonCard(mediaHeight: 0),
            spacing: 10,
          )
        : _error != null
            ? Center(child: Text(_error!))
            : TabBarView(
                children: [
                  _ListingList(
                    items: _agents,
                    hasMore: _hasMore,
                    loadingMore: _loadingMore,
                    onLoadMore: () => _load(more: true),
                    onInstall: _install,
                  ),
                  _ListingList(
                    items: _tools,
                    hasMore: _hasMore,
                    loadingMore: _loadingMore,
                    onLoadMore: () => _load(more: true),
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
                    const Spacer(),
                    ..._actions,
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                _toolbar(compact: true),
                const SizedBox(height: AppSpacing.sm),
                Expanded(child: body),
              ],
            )
          : PanelScaffold(
              compact: compact,
              header: PanelHeader(
                icon: Icons.storefront_outlined,
                title: 'Market',
                subtitle: 'Discover, install, and publish agents & apps',
                onClose: () => Navigator.pop(context),
                actions: _actions,
              ),
              toolbar: _toolbar(compact: compact),
              body: body,
            ),
    );
  }
}

class _ListingList extends StatelessWidget {
  const _ListingList({
    required this.items,
    this.onInstall,
    this.hasMore = false,
    this.loadingMore = false,
    this.onLoadMore,
  });

  final List<MarketListing> items;

  /// Null on the Apps tab: installing an app has no effect.
  final ValueChanged<MarketListing>? onInstall;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return PanelEmpty(
        icon: onInstall == null
            ? Icons.apps_outlined
            : Icons.smart_toy_outlined,
        title: 'Nothing published here yet',
        message: onInstall == null
            ? 'Apps appear here when creators publish them.'
            : 'Browse and install agents once they hit the market.',
      );
    }
    // Resolve the wide/narrow layout once for the list — avoids a
    // LayoutBuilder on every card during scroll.
    final wide = MediaQuery.sizeOf(context).width >= 560;
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
            return const SkeletonCard(mediaHeight: 0);
          }
          return _ListingCard(
            listing: items[i],
            wide: wide,
            onInstall: onInstall == null ? null : () => onInstall!(items[i]),
          );
        },
      ),
    );
  }
}

class _ListingCard extends StatelessWidget {
  const _ListingCard({
    required this.listing,
    required this.wide,
    this.onInstall,
  });

  final MarketListing listing;
  final bool wide;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = listing.isApp ? AppColors.cyanOf(context) : AppColors.primaryOf(context);
    final price =
        listing.price == 0 ? 'Free' : formatLedgerCredits(listing.price);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
            radius: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      listing.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        letterSpacing: -.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SoftMetaChip(
                    label: listing.kindLabel.toUpperCase(),
                    accent: color,
                  ),
                ]),
                if (listing.category.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    listing.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ]),
        if (listing.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            listing.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          SoftMetaChip(
            icon: Icons.download_rounded,
            label: '${listing.installs} installs',
            accent: scheme.onSurfaceVariant,
          ),
          SoftMetaChip(
            icon: Icons.stars_rounded,
            label: price,
            accent: listing.price == 0 ? AppColors.successOf(context) : scheme.primary,
          ),
        ]),
      ],
    );

    final install = onInstall == null
        ? null
        : FilledButton.tonal(
            onPressed: onInstall,
            style: wide
                ? null
                : FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
            child: const Text('Install'),
          );

    return SoftCard(
      showOrb: false,
      padding: const EdgeInsets.all(14),
      child: wide && install != null
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: body),
                const SizedBox(width: 12),
                install,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                body,
                if (install != null) ...[
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: install),
                ],
              ],
            ),
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
                        : AppSurfaces.card(scheme, tokens: AsemanTokens.maybeOf(context)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
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
                        userId: widget.dependencies.sessionController
                                .session?.accountId ??
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
