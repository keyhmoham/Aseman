import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_surfaces.dart';
import '../../features/account/presentation/account_panel.dart';
import '../../features/admin/presentation/admin_screen.dart';
import '../../features/agents/presentation/agents_screen.dart';
import '../../features/developer/presentation/developer_console.dart';
import '../../features/market/presentation/market_screen.dart';
import '../../features/messenger/presentation/messenger_panel.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/talent/presentation/talent_requests_panel.dart';
import 'avatar_editor.dart';
import 'overlay_panels.dart';
import 'user_profile_sheet.dart';

enum ProfileAction {
  profile,
  myBots,
  market,
  wallet,
  messages,
  talent,
  developer,
  invitations,
  usage,
  account,
  admin,
  settings,
  logout,
}

/// Opens the profile menu anchored at the app-bar avatar. On desktop it is an
/// animated floating popup; on mobile it is a standard bottom sheet. Both
/// present the account header above a single-colour action grid. [showMessages]
/// is for the workspace desk — the feed reaches chats through its own entry.
Future<void> showProfileMenu(
  BuildContext context,
  AppDependencies dependencies, {
  bool showMessages = false,
}) async {
  final compact = MediaQuery.sizeOf(context).width < 820;
  final ProfileAction? action;
  if (compact) {
    action = await showModalBottomSheet<ProfileAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * .92,
        ),
        child: SingleChildScrollView(
          child: _ProfileBody(
            dependencies: dependencies,
            showAdmin: dependencies.sessionController.isAdmin,
            showMessages: showMessages,
            onSelect: (a) => Navigator.pop(sheetContext, a),
          ),
        ),
      ),
    );
  } else {
    // A floating panel anchored under the avatar. (A popup menu would grey
    // the whole body out, since it can only hold it as a disabled item.)
    final width = math.min(372.0, MediaQuery.sizeOf(context).width - 32);
    action = await showGeneralDialog<ProfileAction>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close profile menu',
      barrierColor: AppSurfaces.barrier,
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (dialogContext, _, __) => SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 66, 16, 16),
            child: FloatingPanelSurface(
              elevation: 6,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  child: _ProfileBody(
                    dependencies: dependencies,
                    showAdmin: false,
                    showMessages: showMessages,
                    onSelect: (a) => Navigator.pop(dialogContext, a),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (routeContext, animation, __, child) =>
          desktopFloatingPanelTransition(routeContext, animation, child),
    );
  }
  if (action != null) await _dispatch(context, dependencies, action);
}

Future<void> _dispatch(
  BuildContext context,
  AppDependencies dependencies,
  ProfileAction action,
) async {
  switch (action) {
    case ProfileAction.profile:
      await showFloatingPanel(
        context,
        UserProfileSheet(dependencies: dependencies),
        maxWidth: 760,
      );
    case ProfileAction.myBots:
      await showFloatingPanel(
        context,
        AgentsScreen(dependencies: dependencies),
        maxWidth: 900,
      );
    case ProfileAction.market:
      await showFloatingPanel(
        context,
        MarketScreen(dependencies: dependencies),
        maxWidth: 820,
      );
    case ProfileAction.wallet:
      await showAccountPanel(context, dependencies, AccountArea.wallet);
    case ProfileAction.messages:
      await showMessenger(context, dependencies);
    case ProfileAction.talent:
      await showTalentRequests(context, dependencies);
    case ProfileAction.developer:
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => DeveloperConsole(service: dependencies.service)));
    case ProfileAction.invitations:
      await showAccountPanel(context, dependencies, AccountArea.invitations);
    case ProfileAction.usage:
      await showAccountPanel(context, dependencies, AccountArea.usage);
    case ProfileAction.account:
      await showAccountPanel(context, dependencies, AccountArea.account);
    case ProfileAction.admin:
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AdminScreen(dependencies: dependencies),
      ));
    case ProfileAction.settings:
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(dependencies: dependencies)));
    case ProfileAction.logout:
      await dependencies.sessionController.logout();
  }
}

/// Shared body for the popup menu and the bottom sheet: header + unified
/// action grid. [onSelect] closes the enclosing route with the chosen action.
class _ProfileBody extends StatelessWidget {
  const _ProfileBody({
    required this.dependencies,
    required this.showAdmin,
    required this.showMessages,
    required this.onSelect,
  });

  final AppDependencies dependencies;
  final bool showAdmin;
  final bool showMessages;
  final ValueChanged<ProfileAction> onSelect;

  List<_GridItem> get _items => [
        const _GridItem(ProfileAction.profile, Icons.person_outline_rounded,
            'Profile'),
        const _GridItem(
            ProfileAction.myBots, Icons.smart_toy_outlined, 'My bots'),
        const _GridItem(
            ProfileAction.market, Icons.storefront_outlined, 'Market'),
        const _GridItem(ProfileAction.wallet,
            Icons.account_balance_wallet_outlined, 'Wallet'),
        if (showMessages)
          const _GridItem(
              ProfileAction.messages, Icons.forum_outlined, 'Messages'),
        const _GridItem(ProfileAction.invitations,
            Icons.mark_email_unread_outlined, 'Invitations'),
        const _GridItem(
            ProfileAction.usage, Icons.query_stats_outlined, 'Usage'),
        const _GridItem(ProfileAction.talent, Icons.work_outline_rounded,
            'Hire talent'),
        const _GridItem(
            ProfileAction.developer, Icons.api_rounded, 'Developer API'),
        const _GridItem(ProfileAction.account,
            Icons.manage_accounts_outlined, 'Account'),
        if (showAdmin)
          const _GridItem(ProfileAction.admin,
              Icons.admin_panel_settings_outlined, 'Admin console'),
        const _GridItem(
            ProfileAction.logout, Icons.logout_rounded, 'Log out',
            danger: true),
      ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = dependencies.sessionController.session;
    final handle = session?.handle ?? 'guest';
    final initials = handle.isEmpty ? '?' : handle[0].toUpperCase();
    final items = _items;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(AppShape.inner + 2),
            ),
            child: Row(children: [
              AvatarEditor(
                service: dependencies.service,
                avatar: dependencies.sessionController.avatar,
                initials: initials,
                filled: true,
                radius: 24,
                subject: 'profile picture',
                enabled: session?.isLoggedIn ?? false,
                onChanged: dependencies.sessionController.setAvatar,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('@$handle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(session?.accountId ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Settings',
                onPressed: () => onSelect(ProfileAction.settings),
                icon: const Icon(Icons.settings_outlined, size: 20),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.05,
            ),
            itemBuilder: (context, i) => _GridTile(
              item: items[i],
              onSelect: onSelect,
            ),
          ),
        ],
      ),
    );
  }
}

class _GridItem {
  const _GridItem(this.action, this.icon, this.label, {this.danger = false});
  final ProfileAction action;
  final IconData icon;
  final String label;
  final bool danger;
}

/// One tile of the unified action grid.
class _GridTile extends StatelessWidget {
  const _GridTile({required this.item, required this.onSelect});

  final _GridItem item;
  final ValueChanged<ProfileAction> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent =
        item.danger ? AppColors.danger : scheme.onSurfaceVariant;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: .55),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.inner)),
      child: InkWell(
        onTap: () => onSelect(item.action),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, size: 24, color: accent),
              const SizedBox(height: 8),
              Text(item.label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: item.danger
                          ? AppColors.danger
                          : scheme.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}
