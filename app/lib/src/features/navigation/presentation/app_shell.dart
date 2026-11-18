import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_dependencies.dart';
import '../../../core/deferred/deferred_loader.dart';
import '../../../core/layout/app_layout.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/halo_ring_cache.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../shared/widgets/avatar_face.dart';
import '../../../shared/widgets/profile_menu.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../assistant/assistant.dart';
import '../../gadgets/presentation/gadgets_controller.dart';
import '../../home/presentation/workspace_entry.dart' as workspace_entry;
import '../../market/presentation/bots_store_screen.dart' deferred as store_ui;
import '../../messenger/presentation/chats_page.dart';
import '../../search_feed/presentation/rich_post_content.dart';
import '../../search_feed/presentation/search_feed_screen.dart';
import '../../settings/presentation/settings_screen.dart'
    deferred as settings_ui;
import 'deferred_destination.dart';

/// The store, settings and workspace libraries load on first use.
final _storeLibrary = DeferredLoader(() => store_ui.loadLibrary());
final _settingsLibrary = DeferredLoader(() => settings_ui.loadLibrary());

enum _ShellDestination { home, chats, store, settings }

/// Root shell.
///
/// Compact windows keep the existing phone shell (bottom pill navigation).
/// Expanded and wider windows get a collapsed Material 3 navigation rail
/// (icons with labels underneath, no expand control) and render every
/// destination inside the content pane, so navigation, back behaviour and
/// window-size class stay consistent on desktop.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.dependencies});
  final AppDependencies dependencies;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String _workspace = 'Home';
  String? _initialSpaceId;

  /// Room to select when the workspace page opens, from the home chats list.
  String? _initialRoom;
  String? _initialRoomId;

  /// Phone home tab. Chats on first land and when leaving a workspace.
  HomeMobileTab _mobileTab = HomeMobileTab.chats;

  /// Bumps whenever the workspace is opened from outside (feed, chats,
  /// spaces). Decides when the docked workspace gets a fresh state; internal
  /// switches keep the same screen mounted.
  int _workspaceEpoch = 0;

  /// Desktop destination and whether a space is open inside the shell.
  _ShellDestination _destination = _ShellDestination.home;
  bool _inWorkspace = false;

  @override
  void initState() {
    super.initState();
    // A post's author (or a shared post's original author) opens their
    // profile wherever the post shows.
    PostLinks.openAccount = (context, accountId, handle) {
      unawaited(
        workspace_entry.showAccountProfile(
          context,
          widget.dependencies,
          accountId: accountId,
          handle: handle,
        ),
      );
    };
    // On a desktop where the person let agents use this computer, keep
    // answering them.
    hostAgentFor(widget.dependencies).restore().ignore();
    unawaited(_firstDay());
  }

  /// On a person's first day the lead greets them in their home chat and
  /// asks what they work on; the setup checklist then shows what is left.
  Future<void> _firstDay() async {
    try {
      final out = await widget.dependencies.service.invokeAction(
        'proactive',
        'first_day',
      );
      if (!mounted || out is! Map || out['started'] != true) return;
      await openPanel(context, SetupPanel(dependencies: widget.dependencies));
    } catch (_) {
      // No proactive work on this node.
    }
  }

  bool get _desktop => AppWindowClass.of(context).hasNavigationRail;

  int get _selectedDestination => _destination.index;

  void _selectDestination(int index) {
    if (index < 0 || index >= _ShellDestination.values.length) return;
    setState(() {
      _destination = _ShellDestination.values[index];
      _inWorkspace = false;
    });
  }

  void _openWorkspace(String name) {
    _openWorkspaceWithId(name, spaceId: '');
  }

  /// Opens [name]. Desktop windows keep the shell around the workspace;
  /// compact windows still push the workspace full-screen.
  Future<void> _openWorkspaceWithId(String name, {String spaceId = ''}) async {
    if (!_desktop) {
      _workspace = name;
      _initialSpaceId = spaceId.isEmpty ? null : spaceId;
      _initialRoom = null;
      _initialRoomId = null;
      return _pushWorkspace();
    }
    await workspace_entry.loadWorkspace();
    if (!mounted) return;
    setState(() {
      _workspace = name;
      _initialSpaceId = spaceId.isEmpty ? null : spaceId;
      _initialRoom = null;
      _initialRoomId = null;
      _workspaceEpoch++;
      _inWorkspace = true;
      _destination = _ShellDestination.chats;
    });
  }

  /// Opens [name] with the room from the home chats list already selected.
  void _openWorkspaceRoom(
    String spaceId,
    String spaceName,
    String roomName,
    String roomId,
  ) {
    if (!_desktop) {
      _workspace = spaceName;
      _initialSpaceId = spaceId.isEmpty ? null : spaceId;
      _initialRoom = roomName;
      _initialRoomId = roomId;
      unawaited(_pushWorkspace());
      return;
    }
    unawaited(_openDesktopRoom(spaceId, spaceName, roomName, roomId));
  }

  Future<void> _openDesktopRoom(
    String spaceId,
    String spaceName,
    String roomName,
    String roomId,
  ) async {
    await workspace_entry.loadWorkspace();
    if (!mounted) return;
    setState(() {
      _workspace = spaceName;
      _initialSpaceId = spaceId.isEmpty ? null : spaceId;
      _initialRoom = roomName;
      _initialRoomId = roomId;
      _workspaceEpoch++;
      _inWorkspace = true;
      _destination = _ShellDestination.chats;
    });
  }

  /// Whether a workspace route is already on the stack (compact windows), so
  /// a double tap cannot push a second desk.
  bool _workspacePushed = false;

  /// Pushes the workspace desk above Home on compact windows, exactly like a
  /// direct chat: a normal page route that Home stays under, and that back
  /// (system or the header's back control) pops one step. The workspace
  /// library is deferred so Pulse/login do not download the desk + tools +
  /// Elpian stack until a space is opened.
  Future<void> _pushWorkspace() async {
    if (_workspacePushed) return;
    _workspacePushed = true;
    try {
      await workspace_entry.loadWorkspace();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'workspace'),
          builder: (context) => workspace_entry.workspaceScreen(
            key: ValueKey(
              'workspace-desk-$_workspace-${_initialSpaceId ?? ''}-'
              '${_initialRoomId ?? _initialRoom ?? ''}',
            ),
            dependencies: widget.dependencies,
            initialWorkspace: _workspace,
            initialSpaceId: _initialSpaceId,
            initialRoom: _initialRoom,
            initialRoomId: _initialRoomId,
            onBackToFeed: _popWorkspace,
            onWorkspaceChanged: _setWorkspace,
          ),
        ),
      );
    } finally {
      _workspacePushed = false;
      _onReturnedHome();
    }
  }

  /// Back from a pushed workspace: one step, like leaving a direct chat.
  void _popWorkspace() {
    if (!mounted) return;
    unawaited(Navigator.of(context).maybePop());
  }

  /// After any pop back to Home (Home control or system back), land on chats
  /// and retarget the gadgets manager to account / universal gadgets only.
  void _onReturnedHome() {
    if (!mounted) return;
    setState(() => _mobileTab = HomeMobileTab.chats);
    GadgetsScope.maybeOf(context)?.attach();
  }

  /// Workspace Home: pop every route above the feed, or leave the docked
  /// workspace on desktop. Home stays the first route — never push or
  /// replace it.
  void _popToHome() {
    if (!mounted) return;
    if (_desktop) {
      setState(() {
        _inWorkspace = false;
        _destination = _ShellDestination.chats;
      });
      GadgetsScope.maybeOf(context)?.attach();
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
  }

  void _setWorkspace(String name) => setState(() => _workspace = name);

  void _openSearch() {
    unawaited(
      workspace_entry.showExplore(
        context,
        widget.dependencies,
        onOpenSpace: (name) => unawaited(_openWorkspaceWithId(name)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final windowClass = AppWindowClass.of(context);
    if (!windowClass.hasNavigationRail) {
      // Compact / medium: the phone shell owns its own bottom navigation.
      return SearchFeedScreen(
        key: ValueKey('search-feed-$_workspace-$_mobileTab'),
        dependencies: widget.dependencies,
        workspace: _workspace,
        onOpenWorkspace: _openWorkspace,
        onOpenSpaceRoom: (spaceId, spaceName, roomName, roomId) =>
            _openWorkspaceRoom(spaceId, spaceName, roomName, roomId),
        initialMobileTab: _mobileTab,
      );
    }
    return AppWindowScope(
      widthClass: windowClass,
      heightClass: AppHeightClass.fromHeight(MediaQuery.sizeOf(context).height),
      child: _DesktopShell(
        selectedIndex: _selectedDestination,
        onDestinationSelected: _selectDestination,
        onSearch: _openSearch,
        dependencies: widget.dependencies,
        body: AppContentMedia(child: _desktopBody(windowClass)),
      ),
    );
  }

  Widget _desktopBody(AppWindowClass windowClass) {
    if (_inWorkspace) {
      return workspace_entry.workspaceScreen(
        key: ValueKey('workspace-desk-$_workspaceEpoch'),
        dependencies: widget.dependencies,
        initialWorkspace: _workspace,
        initialSpaceId: _initialSpaceId,
        initialRoom: _initialRoom,
        initialRoomId: _initialRoomId,
        onBackToFeed: _popToHome,
        onWorkspaceChanged: _setWorkspace,
        desktopShell: true,
      );
    }
    switch (_destination) {
      case _ShellDestination.home:
        return SearchFeedScreen(
          key: ValueKey('search-feed-desktop-$_workspace'),
          dependencies: widget.dependencies,
          workspace: _workspace,
          desktopShell: true,
          onOpenWorkspace: _openWorkspace,
          onOpenSpaceRoom: (spaceId, spaceName, roomName, roomId) =>
              _openWorkspaceRoom(spaceId, spaceName, roomName, roomId),
          initialMobileTab: _mobileTab,
        );
      case _ShellDestination.chats:
        return ChatsPage(
          dependencies: widget.dependencies,
          onOpenSpaceRoom: _openWorkspaceRoom,
          onOpenWorkspace: _openWorkspace,
        );
      case _ShellDestination.store:
        return DeferredDestination(
          loader: _storeLibrary,
          builder: (context) => ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              child: store_ui.BotsStoreScreen(
                dependencies: widget.dependencies,
                fullPage: true,
              ),
            ),
          ),
        );
      case _ShellDestination.settings:
        return DeferredDestination(
          loader: _settingsLibrary,
          builder: (_) =>
              settings_ui.SettingsScreen(dependencies: widget.dependencies),
        );
    }
  }
}

/// The desktop shell: a docked Material 3 navigation rail around the
/// destination body, with standard keyboard shortcuts.
class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onSearch,
    required this.dependencies,
    required this.body,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onSearch;
  final AppDependencies dependencies;
  final Widget body;

  static const _destinations = <AppDestination>[
    AppDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
    ),
    AppDestination(
      label: 'Chats',
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum_rounded,
    ),
    AppDestination(
      label: 'Store',
      icon: Icons.storefront_outlined,
      selectedIcon: Icons.storefront_rounded,
    ),
    AppDestination(
      label: 'Settings',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
    ),
  ];

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): onSearch,
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): onSearch,
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
          onDestinationSelected(_ShellDestination.settings.index),
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
          onDestinationSelected(_ShellDestination.settings.index),
    };
    for (var i = 0; i < _destinations.length; i++) {
      final index = i;
      final key = switch (i) {
        0 => LogicalKeyboardKey.digit1,
        1 => LogicalKeyboardKey.digit2,
        2 => LogicalKeyboardKey.digit3,
        3 => LogicalKeyboardKey.digit4,
        _ => LogicalKeyboardKey.digit5,
      };
      bindings[SingleActivator(key, meta: true)] = () =>
          onDestinationSelected(index);
      bindings[SingleActivator(key, control: true)] = () =>
          onDestinationSelected(index);
    }
    return bindings;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: scheme.surface,
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NavigationRail(
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                extended: false,
                minWidth: AppLayout.navigationRailWidth,
                groupAlignment: -1,
                labelType: NavigationRailLabelType.all,
                backgroundColor: scheme.surfaceContainerLow,
                indicatorShape: const StadiumBorder(),
                leadingAtTop: true,
                trailingAtBottom: true,
                leading: _RailHeader(onSearch: onSearch),
                trailing: _RailFooter(dependencies: dependencies),
                destinations: [
                  for (final destination in _destinations)
                    NavigationRailDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: Text(destination.label),
                      padding: const EdgeInsets.symmetric(vertical: 2),
                    ),
                ],
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: scheme.outlineVariant,
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.onSearch});

  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Column(
        children: [
          IconButton(
            tooltip: 'Search',
            onPressed: onSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          const SizedBox(height: 8),
          Tooltip(
            message: 'Aseman',
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: ThemeChrome.paintsAtmosphere(context)
                    ? null
                    : scheme.surfaceContainerHigh,
                border: ThemeChrome.paintsAtmosphere(context)
                    ? null
                    : Border.all(color: scheme.outlineVariant),
                gradient: ThemeChrome.paintsAtmosphere(context)
                    ? LinearGradient(colors: [scheme.tertiary, scheme.primary])
                    : null,
              ),
              child: Icon(
                Icons.bolt_rounded,
                size: 22,
                color: ThemeChrome.paintsAtmosphere(context)
                    ? scheme.onPrimary
                    : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailFooter extends StatelessWidget {
  const _RailFooter({required this.dependencies});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: dependencies.sessionController,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final session = dependencies.sessionController.session;
        final handle = session?.handle ?? '';
        final initial = handle.isEmpty ? '?' : handle[0].toUpperCase();
        final accountId = session?.accountId ?? '';
        final picture = dependencies.service.avatarImage(
          dependencies.sessionController.avatar,
        );
        const size = 36.0;
        final corners = context.avatarBorderRadius(size);
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Tooltip(
            message: handle.isEmpty ? 'Account' : '@$handle',
            child: InkWell(
              onTap: () =>
                  showProfileMenu(context, dependencies, anchor: context),
              customBorder: RoundedRectangleBorder(borderRadius: corners),
              child: HaloRing(
                pad: 1.6,
                identity: HaloRingCache.person(accountId),
                borderRadius: corners,
                child: AvatarFace(
                  size: size,
                  borderRadius: corners,
                  backgroundColor: scheme.primary.withValues(alpha: .18),
                  foregroundImage: picture,
                  onImageError: picture == null ? null : (_, __) {},
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
