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
          SoftCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                SkyIconBadge(
                  icon: Icons.palette_rounded,
                  size: 44,
                ),
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
                        'Colors, glass, shapes, and shell layout',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _openStudio,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Create'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Built in',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final pack in DefaultThemePacks.all) ...[
            _ThemePackTile(
              name: pack.meta.name,
              description: pack.meta.description,
              colors: pack.meta.previewColors,
              active: activeId == pack.id,
              onApply: () => _applyBuiltin(pack),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(
            'From the store',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
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
            for (final listing in _listings) ...[
              _ThemePackTile(
                name: listing.name,
                description: listing.description,
                colors: const [],
                active: activeId != null &&
                    ThemePackScope.maybeOf(context)?.listingId == listing.id,
                onApply: () => _installListing(listing),
                trailing: Text(
                  listing.price <= 0 ? 'Free' : '${listing.price}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
        ],
      ),
    );
    return body;
  }
}

class _ThemePackTile extends StatelessWidget {
  const _ThemePackTile({
    required this.name,
    required this.description,
    required this.colors,
    required this.active,
    required this.onApply,
    this.trailing,
  });

  final String name;
  final String description;
  final List<Color> colors;
  final bool active;
  final VoidCallback onApply;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          _Swatch(colors: colors.isEmpty ? [scheme.primary, scheme.tertiary] : colors),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
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
                        ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            trailing!,
            const SizedBox(width: AppSpacing.sm),
          ],
          FilledButton(
            onPressed: active ? null : onApply,
            child: Text(active ? 'Active' : 'Apply'),
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
    final shown = colors.take(3).toList();
    return SizedBox(
      width: 52,
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppShape.borderRadius(context, 16),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: shown.length == 1
                ? [shown.first, shown.first]
                : shown,
          ),
        ),
      ),
    );
  }
}
