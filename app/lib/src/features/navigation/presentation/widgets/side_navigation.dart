import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_surfaces.dart';
import '../../../../core/theme/aseman_tokens.dart';
import '../../../../core/theme/shell_layout.dart';
import '../../../../core/theme/theme_chrome.dart';
import '../../../../core/theme/theme_roles.dart';
import '../../../../core/theme/theme_ui_spec.dart';
import '../../../../shared/widgets/app_brand.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../shared/widgets/theme_slot_host.dart';
import '../../domain/app_destination.dart';

class SideNavigation extends StatelessWidget {
  const SideNavigation(
      {super.key,
      required this.selected,
      required this.onSelect,
      this.handle = 'me',
      this.showAdmin = false});
  final AppDestination selected;
  final ValueChanged<AppDestination> onSelect;
  final String handle;
  final bool showAdmin;

  @override
  Widget build(BuildContext context) => ThemeSlotHost(
        slot: FeatureSlots.workspaceRail,
        child: ThemeSlotHost(
          slot: ThemeChromeSlots.workspaceRail,
          child: SizedBox(
            width: 244,
            child: GlassSurface(
              alpha: AppSurfaces.overlayAlphaOf(context),
              borderRadius: BorderRadius.zero,
              border: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 10, bottom: 28),
                      child: AppBrand(),
                    ),
                    const _Label('WORKSPACE'),
                    for (final item in [
                      AppDestination.home,
                      AppDestination.chats,
                      AppDestination.room
                    ])
                      _Tile(item, selected, onSelect),
                    const SizedBox(height: 18),
                    const _Label('DISCOVER'),
                    for (final item in [
                      AppDestination.explore,
                      AppDestination.agents,
                      AppDestination.wallet
                    ])
                      _Tile(item, selected, onSelect),
                    const Spacer(),
                    if (showAdmin)
                      _Tile(AppDestination.admin, selected, onSelect),
                    const Divider(),
                    Material(
                      color: Colors.transparent,
                      child: ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        leading: AppAvatar(
                          handle.isEmpty ? 'ME' : handle[0].toUpperCase(),
                          color: AppColors.successOf(context),
                        ),
                        title: Text(
                          handle,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          '@$handle',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 8, 8),
      child: Text(text,
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2)));
}

class _Tile extends StatelessWidget {
  const _Tile(this.value, this.selected, this.onSelect);
  final AppDestination value, selected;
  final ValueChanged<AppDestination> onSelect;
  @override
  Widget build(BuildContext context) {
    final active = value == selected;
    final scheme = Theme.of(context).colorScheme;
    final iconSize =
        (AsemanTokens.maybeOf(context)?.language.iconSize ?? 22) - 2;
    return Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Material(
            color: Colors.transparent,
            child: ListTile(
                onTap: () => onSelect(value),
                shape: RoundedRectangleBorder(
                    borderRadius: context.navPillRecipe.borderRadius),
                tileColor:
                    active ? ThemeRoles.selectedFill(context) : null,
                leading: Icon(value.icon,
                    size: iconSize,
                    color: active
                        ? AppColors.cyanOf(context)
                        : scheme.onSurfaceVariant),
                title: Text(value.label,
                    style: TextStyle(
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.w500)))));
  }
}
