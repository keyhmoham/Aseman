import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../features/account/presentation/account_hub_screen.dart';
import '../../features/admin/presentation/admin_screen.dart';
import '../../features/agents/presentation/agents_screen.dart';
import '../../features/chats/presentation/chats_screen.dart';
import '../../features/market/presentation/market_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/wallet/presentation/wallet_screen.dart';
import 'avatar.dart';
import 'overlay_panels.dart';
import 'user_profile_sheet.dart';

enum ProfileAction {
  profile,
  myBots,
  market,
  wallet,
  messages,
  account,
  admin,
  settings,
  logout,
}

/// Opens the profile menu anchored at the app-bar avatar. On desktop it is an
/// animated floating popup; on mobile it is a standard bottom sheet. Both
/// present the account header (with a settings action) above a 2×2 grid of
/// Profile / My bots / Market / Wallet, and a logout row beneath.
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
            showAdmin: true,
            onSelect: (a) => Navigator.pop(sheetContext, a),
          ),
        ),
      ),
    );
  } else {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(360.0, size.width - 32);
    action = await showMenu<ProfileAction>(
      context: context,
      elevation: 18,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(
          color: Theme.of(context)
              .colorScheme
              .outlineVariant
              .withValues(alpha: .6),
        ),
      ),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(size.width - width - 16, 66, width, 0),
        overlay.paintBounds,
      ),
      items: [
        PopupMenuItem<ProfileAction>(
          enabled: false,
          height: 250,
          child: SizedBox(
            width: width,
            child: _ProfileBody(
              dependencies: dependencies,
              showAdmin: false,
              onSelect: (a) => Navigator.pop(context, a),
            ),
          ),
        ),
      ],
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
      await showFloatingPanel(
        context,
        WalletScreen(dependencies: dependencies),
        maxWidth: 760,
      );
    case ProfileAction.messages:
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ChatsScreen(dependencies: dependencies)));
    case ProfileAction.account:
      await showFloatingPanel(
        context,
        AccountHubScreen(dependencies: dependencies),
        maxWidth: 1100,
      );
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            AppAvatar(initials, color: AppColors.primary, radius: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(handle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(session?.accountId ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.muted)),
                ],
              ),
            ),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: IconButton(
                tooltip: 'Settings',
                onPressed: () => onSelect(ProfileAction.settings),
                icon: const Icon(Icons.settings_outlined, size: 20),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            _GridSquare(
              action: ProfileAction.profile,
              icon: Icons.person_outline_rounded,
              label: 'Profile',
              color: AppColors.primary,
              onSelect: onSelect,
            ),
            const SizedBox(width: 12),
            _GridSquare(
              action: ProfileAction.myBots,
              icon: Icons.smart_toy_outlined,
              label: 'My bots',
              color: AppColors.cyan,
              onSelect: onSelect,
            ),
            const SizedBox(width: 12),
            _GridSquare(
              action: ProfileAction.market,
              icon: Icons.storefront_outlined,
              label: 'Market',
              color: AppColors.warning,
              onSelect: onSelect,
            ),
            const SizedBox(width: 12),
            _GridSquare(
              action: ProfileAction.wallet,
              icon: Icons.account_balance_wallet_outlined,
              label: 'Wallet',
              color: AppColors.success,
              onSelect: onSelect,
            ),
          ]),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Column(children: [
            _MenuRow(
              icon: Icons.forum_outlined,
              label: 'Messages',
              onTap: () => onSelect(ProfileAction.messages),
            ),
            const SizedBox(height: 8),
            _MenuRow(
              icon: Icons.manage_accounts_outlined,
              label: 'Account, billing, payouts & usage',
              onTap: () => onSelect(ProfileAction.account),
            ),
            if (showAdmin) ...[
              const SizedBox(height: 8),
              _MenuRow(
                icon: Icons.admin_panel_settings_outlined,
                label: 'Admin console',
                onTap: () => onSelect(ProfileAction.admin),
              ),
            ],
            const SizedBox(height: 8),
            _LogoutRow(onSelect: onSelect),
          ]),
        ),
      ],
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
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Row(children: [
              Icon(icon, size: 19),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700))),
              const Icon(Icons.chevron_right_rounded, size: 17),
            ]),
          ),
        ),
      );
}

/// One square of the 2×2 action grid.
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onSelect(action),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(height: 8),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoutRow extends StatelessWidget {
  const _LogoutRow({required this.onSelect});

  final ValueChanged<ProfileAction> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onSelect(ProfileAction.logout),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.logout_rounded,
                  size: 18, color: AppColors.danger),
            ),
            const SizedBox(width: 12),
            const Text('Log out',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded,
                size: 16, color: AppColors.muted),
          ]),
        ),
      ),
    );
  }
}
