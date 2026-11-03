import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/shell_layout.dart';
import '../../../core/theme/shell_layout_builder.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/panel_scaffold.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../agents/presentation/agents_screen.dart';
import 'market_screen.dart';
import 'themes_store_screen.dart';

/// App-store hub that melts **My bots** and **Market** into one surface:
/// Library for what you own, Discover for what you can install, Themes for
/// installable visual packs.
Future<void> showBotsStore(
  BuildContext context,
  AppDependencies dependencies,
) =>
    showFloatingPanel(
      context,
      BotsStoreScreen(dependencies: dependencies),
      maxWidth: 920,
    );

class BotsStoreScreen extends StatelessWidget {
  const BotsStoreScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    final scheme = Theme.of(context).colorScheme;
    final tabs = storeTabsOf(context);
    final resolved = tabs.isEmpty
        ? const [
            ShellTabMeta(
                FeatureSlots.storeLibrary, 'Library', Icons.grid_view_rounded),
            ShellTabMeta(FeatureSlots.storeDiscover, 'Discover',
                Icons.travel_explore_rounded),
            ShellTabMeta(
                FeatureSlots.storeThemes, 'Themes', Icons.palette_rounded),
          ]
        : tabs;
    return DefaultTabController(
      length: resolved.length,
      child: PanelScaffold(
        compact: compact,
        header: PanelHeader(
          icon: Icons.storefront_rounded,
          title: 'Store',
          subtitle: 'Library, market, and themes — create, install, publish',
          onClose: () => Navigator.pop(context),
        ),
        toolbar: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SoftCard(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm + 2,
                AppSpacing.md,
                AppSpacing.sm + 2,
              ),
              child: Row(
                children: [
                  SkyIconBadge(
                    icon: Icons.auto_awesome_rounded,
                    size: 44,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const EyebrowLabel('STOREFRONT'),
                        const SizedBox(height: 2),
                        Text(
                          'Agents, apps & themes',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -.2,
                                  ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Build in Library · browse Discover · restyle with Themes',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    height: 1.25,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SegmentedTabBar(
              alignment: Alignment.center,
              labels: [for (final t in resolved) t.label],
              icons: [for (final t in resolved) t.icon],
            ),
          ],
        ),
        body: TabBarView(
          children: [
            for (final tab in resolved)
              switch (tab.slot) {
                FeatureSlots.storeLibrary =>
                  AgentsScreen(dependencies: dependencies, embedded: true),
                FeatureSlots.storeDiscover =>
                  MarketScreen(dependencies: dependencies, embedded: true),
                FeatureSlots.storeThemes =>
                  ThemesStoreScreen(dependencies: dependencies, embedded: true),
                _ => const SizedBox.shrink(),
              },
          ],
        ),
      ),
    );
  }
}
