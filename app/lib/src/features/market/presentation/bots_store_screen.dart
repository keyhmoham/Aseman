import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/panel_scaffold.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../agents/presentation/agents_screen.dart';
import 'market_screen.dart';

/// App-store hub that melts **My bots** and **Market** into one surface:
/// Library for what you own, Discover for what you can install.
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
    return DefaultTabController(
      length: 2,
      child: PanelScaffold(
        compact: compact,
        header: PanelHeader(
          icon: Icons.storefront_rounded,
          title: 'Store',
          subtitle: 'Your library and the market — create, install, publish',
          onClose: () => Navigator.pop(context),
        ),
        toolbar: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SoftCard(
              accent: scheme.primary,
              secondary: scheme.tertiary,
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
                    accent: scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const EyebrowLabel('STOREFRONT'),
                        const SizedBox(height: 2),
                        Text(
                          'Agents & apps',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -.2,
                                  ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Build in Library · browse & install in Discover',
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
            const SegmentedTabBar(
              alignment: Alignment.center,
              labels: ['Library', 'Discover'],
              icons: [Icons.grid_view_rounded, Icons.travel_explore_rounded],
            ),
          ],
        ),
        body: TabBarView(
          children: [
            AgentsScreen(dependencies: dependencies, embedded: true),
            MarketScreen(dependencies: dependencies, embedded: true),
          ],
        ),
      ),
    );
  }
}
