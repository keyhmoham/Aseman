import 'package:flutter/material.dart';
import '../../../core/theme/app_shape.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/default_theme_packs.dart';
import '../../../core/theme/theme_pack.dart';
import '../../../core/theme/theme_pack_controller.dart';
import '../../../data/models/bot.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';
import 'theme_studio_screen.dart';

/// Discover / apply installable theme packs (builtins + marketplace).
class ThemesStoreScreen extends StatefulWidget {
  const ThemesStoreScreen({
    super.key,
    required this.dependencies,
    this.embedded = false,
  });

  final AppDependencies dependencies;
  final bool embedded;

  @override
  State<ThemesStoreScreen> createState() => _ThemesStoreScreenState();
}

class _ThemesStoreScreenState extends State<ThemesStoreScreen> {
  List<MarketListing> _listings = [];
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
      final list = await widget.dependencies.service.fetchMarket(
        type: 'theme',
        limit: 50,
      );
      if (!mounted) return;
      setState(() {
        _listings = list;
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

  Future<void> _applyBuiltin(ThemePack pack) async {
    final packs = ThemePackScope.of(context);
    await packs.applyBuiltin(pack.id);
    // Drop the account-level store apply so login cannot restore it.
    try {
      await widget.dependencies.service.uninstallActiveTheme();
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Applied “${pack.meta.name}”')),
    );
    setState(() {});
  }

  Future<void> _installListing(MarketListing listing) async {
    try {
      await widget.dependencies.service.installThemeListing(listing.id);
      final active = await widget.dependencies.service.fetchActiveTheme();
      if (active != null) {
        await ThemePackScope.of(context).syncFromServer(
          next: active.pack,
          listing: listing.id,
          botId: listing.botId,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Theme “${listing.name}” applied')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not install theme: $e')),
      );
    }
  }

  Future<void> _openStudio() async {
    await showThemeStudio(context, widget.dependencies);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeId = ThemePackScope.maybeOf(context)?.pack.id;
    final body = RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.xxl,
        ),
        children: [
          _ThemeMasthead(
            onCreate: _openStudio,
            subtitle: 'Colors, glass, shapes, and shell layout',
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Included with Decillion',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.2,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Swipe the shelf. Applying one restyles the whole app.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 248,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: DefaultThemePacks.all.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final pack = DefaultThemePacks.all[i];
                return SizedBox(
                  width: 176,
                  child: _ThemePoster(
                    name: pack.meta.name,
                    description: pack.meta.description,
                    colors: pack.meta.previewColors,
                    active: activeId == pack.id,
                    onApply: () => _applyBuiltin(pack),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'From the store',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.2,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_loading)
            const SkeletonList(itemCount: 3)
          else if (_error != null)
            PanelEmpty(
              icon: Icons.error_outline_rounded,
              title: 'Could not load themes',
              message: '$_error — pull to retry',
            )
          else if (_listings.isEmpty)
            const PanelEmpty(
              icon: Icons.storefront_outlined,
              title: 'No published themes yet',
              message:
                  'Create one in Theme Studio, or ask Aseman to design one.',
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = (width / 190).floor().clamp(1, 4);
                final tileWidth =
                    (width - (columns - 1) * 12) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final listing in _listings)
                      SizedBox(
                        width: tileWidth,
                        height: 248,
                        child: _ThemePoster(
                          name: listing.name,
                          description: listing.description,
                          colors: const [],
                          price: listing.price <= 0 ? 'Free' : '${listing.price}',
                          active: activeId != null &&
                              ThemePackScope.maybeOf(context)?.listingId ==
                                  listing.id,
                          onApply: () => _installListing(listing),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
    return body;
  }
}

class _ThemeMasthead extends StatelessWidget {
  const _ThemeMasthead({required this.onCreate, required this.subtitle});

  final VoidCallback onCreate;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return SoftCard(
      wash: true,
      elevated: true,
      padding: EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.tertiaryContainer.withValues(alpha: dark ? .7 : .95),
              Color.alphaBlend(
                scheme.primaryContainer.withValues(alpha: dark ? .4 : .5),
                scheme.surface,
              ),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              const SkyIconBadge(icon: Icons.palette_rounded, size: 44),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const EyebrowLabel('THEMES'),
                    Text(
                      'Restyle the whole app',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: onCreate,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Create'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemePoster extends StatelessWidget {
  const _ThemePoster({
    required this.name,
    required this.description,
    required this.colors,
    required this.active,
    required this.onApply,
    this.price,
  });

  final String name;
  final String description;
  final List<Color> colors;
  final bool active;
  final VoidCallback onApply;
  final String? price;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftCard(
      selected: active,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Swatch(
            colors: colors.isEmpty ? [scheme.primary, scheme.tertiary] : colors,
          ),
          const SizedBox(height: 10),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          if (description.isNotEmpty)
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.25,
                  ),
            ),
          const Spacer(),
          Row(
            children: [
              if (price != null)
                Text(
                  price!,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              const Spacer(),
              FilledButton(
                onPressed: active ? null : onApply,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(active ? 'Active' : 'Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final shown = colors.take(4).toList();
    return SizedBox(
      height: 92,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppShape.borderRadius(context, 16),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .7),
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: shown.length == 1 ? [shown.first, shown.first] : shown,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Row(
              children: [
                for (final color in shown.take(3))
                  Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .surface
                            .withValues(alpha: .85),
                        width: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
