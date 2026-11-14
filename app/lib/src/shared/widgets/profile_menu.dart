import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app.dart' show AsemanApp;
import '../../app_dependencies.dart';
import '../../core/deferred/deferred_loader.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_surfaces.dart';
import '../../core/theme/shell_layout.dart';
import '../../core/theme/shell_layout_builder.dart';
import '../../core/theme/theme_ui_spec.dart';
import '../../features/account/presentation/account_panel.dart';
import '../../features/admin/presentation/admin_screen.dart' deferred as admin;
import '../../features/developer/presentation/developer_console.dart'
    deferred as developer;
import '../../features/market/presentation/bots_store_screen.dart'
    deferred as market;
import '../../features/messenger/presentation/messenger_panel.dart';
import '../../features/settings/presentation/settings_screen.dart'
    deferred as settings_ui;
import '../../features/settings/presentation/widgets/devices_panel.dart'
    deferred as devices_ui;
import 'avatar_editor.dart';
import 'overlay_panels.dart';
import 'sky_ui.dart';
import 'theme_slot_host.dart';

// The menu's screens load on first use, each once (DeferredLoader).
final _store = DeferredLoader(() => market.loadLibrary());
final _developerConsole = DeferredLoader(() => developer.loadLibrary());
final _adminConsole = DeferredLoader(() => admin.loadLibrary());
final _settingsScreen = DeferredLoader(() => settings_ui.loadLibrary());
final _devicesPanel = DeferredLoader(() => devices_ui.loadLibrary());

/// Loads the profile menu's screens (store, developer console, admin
/// console, settings, devices).
Future<void> loadProfileScreens() async {
  await Future.wait([
    for (final loader in [
      _store,
      _developerConsole,
      _adminConsole,
      _settingsScreen,
      _devicesPanel,
    ])
      loader.ensure() ?? Future<void>.value(),
  ]);
}

enum ProfileAction {
  store,
  wallet,
  messages,
  devices,
  developer,
  admin,
  settings,
  logout,
}

/// Opens the profile menu anchored at the app-bar avatar. On desktop it is an
/// animated floating popup; on phones outside Home it is a bottom sheet.
/// Home's phone shell shows the same body as the third tab ("You") instead.
/// [showMessages] is for the workspace desk — the feed reaches chats through
/// its own entry.
Future<void> showProfileMenu(
  BuildContext context,
  AppDependencies dependencies, {
  bool showMessages = false,
}) async {
  final compact = MediaQuery.sizeOf(context).width < 820;
  final ProfileAction? action;
  if (compact) {
    action = await showAppSheet<ProfileAction>(
      context,
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .92,
        ),
        child: SingleChildScrollView(
          child: Builder(builder: (sheetContext) {
            return ProfileMenuBody(
              dependencies: dependencies,
              showAdmin: dependencies.sessionController.isAdmin,
              showMessages: showMessages,
              onSelect: (a) => Navigator.pop(sheetContext, a),
            );
          }),
        ),
      ),
      isScrollControlled: true,
    );
  } else {
    final width = math.min(392.0, MediaQuery.sizeOf(context).width - 32);
    action = await showGeneralDialog<ProfileAction>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close profile menu',
      barrierColor: AppSurfaces.barrierOf(context),
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
                  child: ProfileMenuBody(
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
  if (action != null) await dispatchProfileAction(context, dependencies, action);
}

/// Prefer the app navigator — You-tab builder contexts can be deactivated
/// while a deferred library loads (theme sync rebuilds the shell).
BuildContext? _navContext(BuildContext fallback) {
  final nav = AsemanApp.navigatorKey.currentContext;
  if (nav != null && nav.mounted) return nav;
  return fallback.mounted ? fallback : null;
}

Future<void> dispatchProfileAction(
  BuildContext context,
  AppDependencies dependencies,
  ProfileAction action,
) async {
  try {
    switch (action) {
      case ProfileAction.store:
        await _store.ensure();
        final ctx = _navContext(context);
        if (ctx == null) return;
        await market.showBotsStore(ctx, dependencies);
        return;
      case ProfileAction.wallet:
        final ctx = _navContext(context);
        if (ctx == null) return;
        await showAccountPanel(ctx, dependencies, AccountArea.wallet);
        return;
      case ProfileAction.messages:
        final ctx = _navContext(context);
        if (ctx == null) return;
        await showMessenger(ctx, dependencies);
        return;
      case ProfileAction.devices:
        await _devicesPanel.ensure();
        final ctx = _navContext(context);
        if (ctx == null) return;
        await devices_ui.showDevicesPanel(ctx, dependencies);
        return;
      case ProfileAction.developer:
        await _developerConsole.ensure();
        final ctx = _navContext(context);
        if (ctx == null) return;
        await Navigator.of(ctx).push(MaterialPageRoute<void>(
            builder: (_) =>
                developer.DeveloperConsole(service: dependencies.service)));
        return;
      case ProfileAction.admin:
        await _adminConsole.ensure();
        final ctx = _navContext(context);
        if (ctx == null) return;
        await Navigator.of(ctx).push(MaterialPageRoute<void>(
          builder: (_) => admin.AdminScreen(dependencies: dependencies),
        ));
        return;
      case ProfileAction.settings:
        await _settingsScreen.ensure();
        final ctx = _navContext(context);
        if (ctx == null) return;
        await Navigator.of(ctx).push(MaterialPageRoute<void>(
            builder: (_) =>
                settings_ui.SettingsScreen(dependencies: dependencies)));
        return;
      case ProfileAction.logout:
        await dependencies.sessionController.logout();
        return;
    }
  } catch (e) {
    final ctx = _navContext(context);
    if (ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text('Couldn’t open: $e')),
    );
  }
}

/// Profile menu body: identity masthead, two feature stages (Store + Wallet),
/// then a quiet list for the rest — no raw icon grid. Settings lives only on
/// the masthead icon (no duplicate list row).
class ProfileMenuBody extends StatelessWidget {
  const ProfileMenuBody({
    super.key,
    required this.dependencies,
    required this.showAdmin,
    required this.showMessages,
    required this.onSelect,
  });

  final AppDependencies dependencies;
  final bool showAdmin;
  final bool showMessages;
  final ValueChanged<ProfileAction> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = dependencies.sessionController.session;
    final handle = session?.handle ?? 'guest';
    final initials = handle.isEmpty ? '?' : handle[0].toUpperCase();
    final entries = profileEntriesOf(context).toSet();
    final showStore = entries.contains(FeatureSlots.profileStore);
    final showWallet = entries.contains(FeatureSlots.profileWallet);
    final showSettings = entries.contains(FeatureSlots.profileSettings);
    final showAdminEntry =
        showAdmin && entries.contains(FeatureSlots.profileAdmin);
    final islands = themeUiOf(context).islandsFor(ThemeIslandPlacement.profile);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _IdentityMasthead(
            dependencies: dependencies,
            handle: handle,
            initials: initials,
            accountId: session?.accountId ?? '',
            loggedIn: session?.isLoggedIn ?? false,
            onOpenSettings: showSettings
                ? () => onSelect(ProfileAction.settings)
                : null,
          ),
          if (showStore) ...[
            const SizedBox(height: AppSpacing.md),
            ThemeSlotHost(
              slot: FeatureSlots.profileStore,
              child: FeatureStageCard(
                title: 'Store',
                eyebrow: 'Library · Market · Themes',
                subtitle:
                    'Agents, apps and theme packs in one storefront',
                icon: Icons.storefront_rounded,
                accent: scheme.primary,
                secondary: scheme.tertiary,
                badges: const [
                  FeatureStageBadge(Icons.smart_toy_outlined, 'My bots'),
                  FeatureStageBadge(Icons.travel_explore_rounded, 'Market'),
                  FeatureStageBadge(Icons.palette_outlined, 'Themes'),
                ],
                onTap: () => onSelect(ProfileAction.store),
              ),
            ),
          ],
          if (showWallet) ...[
            const SizedBox(height: AppSpacing.sm),
            ThemeSlotHost(
              slot: FeatureSlots.profileWallet,
              child: FeatureStageCard(
                title: 'Wallet',
                eyebrow: 'Balance · Usage',
                subtitle: 'Credits, purchases and what each project spent',
                icon: Icons.account_balance_wallet_rounded,
                accent: scheme.primary,
                secondary: scheme.tertiary,
                badges: const [
                  FeatureStageBadge(Icons.payments_outlined, 'Credits'),
                  FeatureStageBadge(Icons.query_stats_rounded, 'Usage'),
                ],
                onTap: () => onSelect(ProfileAction.wallet),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          QuietList(
            children: [
              if (showMessages)
                QuietTile(
                  icon: Icons.forum_outlined,
                  label: 'Messages',
                  onTap: () => onSelect(ProfileAction.messages),
                ),
              QuietTile(
                icon: Icons.devices_outlined,
                label: 'Devices',
                onTap: () => onSelect(ProfileAction.devices),
              ),
              QuietTile(
                icon: Icons.api_rounded,
                label: 'Developer API',
                onTap: () => onSelect(ProfileAction.developer),
              ),
              if (showAdminEntry)
                ThemeSlotHost(
                  slot: FeatureSlots.profileAdmin,
                  child: QuietTile(
                    icon: Icons.admin_panel_settings_outlined,
                    label: 'Admin console',
                    onTap: () => onSelect(ProfileAction.admin),
                  ),
                ),
              for (final island in islands)
                ThemeSlotHost(
                  slot: island.id,
                  child: QuietTile(
                    icon: island.iconData,
                    label: island.title,
                    onTap: () => openThemeIslandPage(context, island),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          QuietTile(
            icon: Icons.logout_rounded,
            label: 'Log out',
            danger: true,
            onTap: () => onSelect(ProfileAction.logout),
          ),
        ],
      ),
    );
  }
}

/// Soft identity card — avatar + handle, with Settings as the only chrome
/// control (profile & account live inside Settings).
class _IdentityMasthead extends StatelessWidget {
  const _IdentityMasthead({
    required this.dependencies,
    required this.handle,
    required this.initials,
    required this.accountId,
    required this.loggedIn,
    required this.onOpenSettings,
  });

  final AppDependencies dependencies;
  final String handle;
  final String initials;
  final String accountId;
  final bool loggedIn;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftCard(
      accent: scheme.primary,
      radius: AppShape.inner,
      wash: true,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm + 2,
        AppSpacing.sm,
        AppSpacing.sm + 2,
      ),
      child: Row(
        children: [
          AvatarEditor(
            service: dependencies.service,
            avatar: dependencies.sessionController.avatar,
            initials: initials,
            filled: true,
            radius: 24,
            subject: 'profile picture',
            enabled: loggedIn,
            identity: accountId,
            onChanged: dependencies.sessionController.setAvatar,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '@$handle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.2,
                        color: scheme.onSurface,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  accountId.isEmpty ? 'Signed out' : accountId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          if (onOpenSettings != null)
            IconButton.filledTonal(
              tooltip: 'Settings',
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings_outlined, size: 20),
            ),
        ],
      ),
    );
  }
}
