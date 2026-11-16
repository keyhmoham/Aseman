import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/shell_layout.dart';
import '../../../core/theme/shell_layout_builder.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../agents/presentation/agents_screen.dart';
import 'market_screen.dart';
import 'themes_store_screen.dart';

/// Decillion Store: Library for what you own, Discover for what you can
/// install, Themes for installable visual packs.
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
  const BotsStoreScreen({
    super.key,
    required this.dependencies,
    this.fullPage = false,
  });

  final AppDependencies dependencies;

  /// When the screen is a shell destination rather than a floating panel,
  /// there is no route to close and the close control is omitted.
  final bool fullPage;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.compact;
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
      child: Padding(
        padding: AppSpacing.panelPadding(compact).copyWith(bottom: 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StoreBar(
              tabs: resolved,
              onClose: fullPage ? null : () => Navigator.pop(context),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: TabBarView(
                children: [
                  for (final tab in resolved)
                    switch (tab.slot) {
                      FeatureSlots.storeLibrary => AgentsScreen(
                          dependencies: dependencies,
                          embedded: true,
                        ),
                      FeatureSlots.storeDiscover => MarketScreen(
                          dependencies: dependencies,
                          embedded: true,
                        ),
                      FeatureSlots.storeThemes => ThemesStoreScreen(
                          dependencies: dependencies,
                          embedded: true,
                        ),
                      _ => const SizedBox.shrink(),
                    },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Title and store sections on one band. Subtitles and section captions
/// used to stack under this and push the catalog down.
class _StoreBar extends StatelessWidget {
  const _StoreBar({required this.tabs, this.onClose});

  final List<ShellTabMeta> tabs;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = Text(
      'Decillion Store',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -.3,
          ),
    );
    final mark = Icon(Icons.storefront_rounded, size: 18, color: scheme.primary);
    final sections = SegmentedTabBar(
      alignment: Alignment.centerLeft,
      labels: [for (final t in tabs) t.label],
      icons: [for (final t in tabs) t.icon],
    );
    final close = onClose == null
        ? null
        : IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          );
    return LayoutBuilder(
      builder: (context, box) {
        final stacked = box.maxWidth < 560;
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  mark,
                  const SizedBox(width: 8),
                  Expanded(child: title),
                  if (close != null) close,
                ],
              ),
              const SizedBox(height: 4),
              sections,
            ],
          );
        }
        return Row(
          children: [
            mark,
            const SizedBox(width: 8),
            title,
            const SizedBox(width: 14),
            Expanded(child: sections),
            if (close != null) close,
          ],
        );
      },
    );
  }
}
