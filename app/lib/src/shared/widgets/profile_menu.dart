import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../features/account/presentation/account_panel.dart';
import '../../features/admin/presentation/admin_screen.dart';
import '../../features/agents/presentation/agents_screen.dart';
import '../../features/market/presentation/market_screen.dart';
import '../../features/messenger/presentation/messenger_panel.dart';
import '../../features/settings/presentation/settings_screen.dart';
import 'overlay_panels.dart';
import 'user_profile_sheet.dart';

enum ProfileAction {
  profile,
  myBots,
  market,
  wallet,
  messages,
  invitations,
  usage,
  account,
  admin,
  settings,
  logout,
}

/// Opens the profile menu anchored at the app-bar avatar. On desktop it is an
/// animated floating popup; on mobile it is a standard bottom sheet. Both
/// present the account header (with a settings action) above a row of
/// Profile / My bots / Market / Wallet, then Messages, Invitations, Usage and
/// Account, and a logout row beneath. Each item opens as its own modal panel.
Future<void> showProfileMenu(
  BuildContext context,
  AppDependencies dependencies,
) async {
  final compact = MediaQuery.sizeOf(context).width < 820;
  final ProfileAction? action;
  if (compact) {
    action = await showModalBottomSheet<ProfileAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * .92,
        ),
        child: SingleChildScrollView(
          child: _ProfileBody(
            dependencies: dependencies,
            showAdmin: dependencies.sessionController.isAdmin,
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
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dialogContext, _, __) => SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 66, 16, 16),
            child: Material(
              color: Theme.of(dialogContext).colorScheme.surfaceContainer,
              elevation: 6,
              shadowColor: Colors.black45,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppShape.card)),
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  child: _ProfileBody(
                    dependencies: dependencies,
                    showAdmin: false,
                    onSelect: (a) => Navigator.pop(dialogContext, a),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (_, animation, __, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
              alignment: Alignment.topRight,
              scale: Tween(begin: .92, end: 1.0).animate(curved),
              child: child),
        );
      },
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

/// Shared body for the popup menu and the bottom sheet: header + grid +
/// logout row. [onSelect] closes the enclosing route with the chosen action.
class _ProfileBody extends StatelessWidget {
  const _ProfileBody({
    required this.dependencies,
    required this.showAdmin,
    required this.onSelect,
  });

  final AppDependencies dependencies;
  final bool showAdmin;
  final ValueChanged<ProfileAction> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = dependencies.sessionController.session;
    final handle = session?.handle ?? 'guest';
    final initials = handle.isEmpty ? '?' : handle[0].toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The account, on the primary container like other hero surfaces.
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppShape.inner + 2),
            ),
            child: Row(children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                child: Text(initials,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
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
                            color: scheme.onPrimaryContainer)),
                    const SizedBox(height: 2),
                    Text(session?.accountId ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onPrimaryContainer
                                .withValues(alpha: .7))),
                  ],
                ),
              ),
              IconButton.filled(
                tooltip: 'Settings',
                style: IconButton.styleFrom(
                    backgroundColor: scheme.surface.withValues(alpha: .5),
                    foregroundColor: scheme.onPrimaryContainer),
                onPressed: () => onSelect(ProfileAction.settings),
                icon: const Icon(Icons.settings_outlined, size: 20),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            _GridSquare(
              action: ProfileAction.profile,
              icon: Icons.person_outline_rounded,
              label: 'Profile',
              color: AppColors.primary,
              onSelect: onSelect,
            ),
            const SizedBox(width: 8),
            _GridSquare(
              action: ProfileAction.myBots,
              icon: Icons.smart_toy_outlined,
              label: 'My bots',
              color: AppColors.cyan,
              onSelect: onSelect,
            ),
            const SizedBox(width: 8),
            _GridSquare(
              action: ProfileAction.market,
              icon: Icons.storefront_outlined,
              label: 'Market',
              color: AppColors.warning,
              onSelect: onSelect,
            ),
            const SizedBox(width: 8),
            _GridSquare(
              action: ProfileAction.wallet,
              icon: Icons.account_balance_wallet_outlined,
              label: 'Wallet',
              color: AppColors.success,
              onSelect: onSelect,
            ),
          ]),
          const SizedBox(height: 12),
          // One grouped list, rounded as a whole, like M3 list sections.
          ClipRRect(
            borderRadius: BorderRadius.circular(AppShape.inner),
            child: Column(children: [
              _MenuRow(
                icon: Icons.forum_outlined,
                label: 'Messages',
                onTap: () => onSelect(ProfileAction.messages),
              ),
              const SizedBox(height: 2),
              _MenuRow(
                icon: Icons.mark_email_unread_outlined,
                label: 'Invitations',
                onTap: () => onSelect(ProfileAction.invitations),
              ),
              const SizedBox(height: 2),
              _MenuRow(
                icon: Icons.query_stats_outlined,
                label: 'Usage',
                onTap: () => onSelect(ProfileAction.usage),
              ),
              const SizedBox(height: 2),
              _MenuRow(
                icon: Icons.manage_accounts_outlined,
                label: 'Account',
                onTap: () => onSelect(ProfileAction.account),
              ),
              if (showAdmin) ...[
                const SizedBox(height: 2),
                _MenuRow(
                  icon: Icons.admin_panel_settings_outlined,
                  label: 'Admin console',
                  onTap: () => onSelect(ProfileAction.admin),
                ),
              ],
              const SizedBox(height: 2),
              _LogoutRow(onSelect: onSelect),
            ]),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: .6),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Icon(icon, size: 21, color: scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600))),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

/// One tile of the shortcut row.
class _GridSquare extends StatelessWidget {
  const _GridSquare({
    required this.action,
    required this.icon,
    required this.label,
    required this.color,
    required this.onSelect,
  });

  final ProfileAction action;
  final IconData icon;
  final String label;
  final Color color;
  final ValueChanged<ProfileAction> onSelect;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Material(
          color: color.withValues(alpha: .13),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppShape.inner)),
          child: InkWell(
            onTap: () => onSelect(action),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 24, color: color),
                  const SizedBox(height: 8),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ),
      );
}

class _LogoutRow extends StatelessWidget {
  const _LogoutRow({required this.onSelect});

  final ValueChanged<ProfileAction> onSelect;

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.danger.withValues(alpha: .1),
        child: InkWell(
          onTap: () => onSelect(ProfileAction.logout),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Icon(Icons.logout_rounded, size: 21, color: AppColors.danger),
              SizedBox(width: 14),
              Text('Log out',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.danger)),
            ]),
          ),
        ),
      );
}
