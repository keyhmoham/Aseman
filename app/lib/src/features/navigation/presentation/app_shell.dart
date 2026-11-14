import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../assistant/assistant.dart';
import '../../gadgets/presentation/gadgets_controller.dart';
import '../../home/presentation/workspace_entry.dart' as workspace_entry;
import '../../search_feed/presentation/rich_post_content.dart';
import '../../search_feed/presentation/search_feed_screen.dart';

/// Root shell: the search feed (Pulse) is the landing page after login.
/// Picking a workspace from the app bar pushes that workspace's home desk
/// onto the navigator; the workspace Home control pops back to this feed
/// (never pushes or replaces Home). On phones the profile lives in Home's
/// You tab; on wide screens the app-bar avatar opens the profile menu.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.dependencies});
  final AppDependencies dependencies;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String _workspace = 'Home';

  /// Space id when opening from chats (preferred over name).
  String? _initialSpaceId;

  /// Room to select when the workspace page opens, from the home chats list.
  String? _initialRoom;
  String? _initialRoomId;

  /// Phone home tab. Chats on first land and when leaving a workspace.
  HomeMobileTab _mobileTab = HomeMobileTab.chats;

  @override
  void initState() {
    super.initState();
    // A post's author (or a shared post's original author) opens their
    // profile wherever the post shows.
    PostLinks.openAccount = (context, accountId, handle) {
      unawaited(workspace_entry.showAccountProfile(
        context,
        widget.dependencies,
        accountId: accountId,
        handle: handle,
      ));
    };
    // On a desktop where the person let agents use this computer, keep
    // answering them.
    hostAgentFor(widget.dependencies).restore().ignore();
    // Expo has no proactive.first_day; setup uses proactive.setup_check.
    unawaited(_setupCheck());
  }

  /// Opens the setup checklist when the node still has unfinished setup items
  /// (`proactive.setup_check` — Expo SOT).
  Future<void> _setupCheck() async {
    try {
      final out = await widget.dependencies.service.invokeAction(
        'proactive',
        'setup_check',
      );
      if (!mounted || out is! Map) return;
      final items = out['items'];
      if (items is! List || items.isEmpty) return;
      await openPanel(context, SetupPanel(dependencies: widget.dependencies));
    } catch (_) {
      // No proactive work on this node.
    }
  }

  void _openWorkspace(String name, {String spaceId = ''}) {
    _workspace = name;
    _initialSpaceId = spaceId.isEmpty ? null : spaceId;
    _initialRoom = null;
    _initialRoomId = null;
    unawaited(_pushWorkspace());
  }

  /// Opens a project (by id when known) with the room from the chats list.
  void _openWorkspaceRoom(
    String spaceId,
    String name,
    String roomName,
    String roomId,
  ) {
    _workspace = name;
    _initialSpaceId = spaceId.isEmpty ? null : spaceId;
    _initialRoom = roomName;
    _initialRoomId = roomId;
    unawaited(_pushWorkspace());
  }

  /// Pushes the workspace desk above Home. Zero-duration route so each page
  /// still owns its own panel motion (same as the old page swap).
  ///
  /// The workspace library is deferred so Pulse/login do not download the
  /// desk + tools + Elpian stack until a space is opened.
  Future<void> _pushWorkspace() async {
    await workspace_entry.loadWorkspace();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    // Avoid stacking a second desk if Home somehow fires again while one is
    // already open; pop back to Home first, then push the requested desk.
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
    unawaited(
      navigator
          .push<void>(
        PageRouteBuilder<void>(
          settings: const RouteSettings(name: 'workspace'),
          opaque: true,
          // Drop Home's subtree while a workspace covers it so only the desk is
          // mounted (same as the old page swap); popping rebuilds Home.
          maintainState: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              workspace_entry.workspaceScreen(
            key: ValueKey(
                'workspace-desk-${_initialSpaceId ?? _workspace}'),
            dependencies: widget.dependencies,
            initialWorkspace: _workspace,
            initialSpaceId: _initialSpaceId,
            initialRoom: _initialRoom,
            initialRoomId: _initialRoomId,
            onBackToFeed: _popToHome,
            onWorkspaceChanged: _setWorkspace,
          ),
        ),
      )
          .whenComplete(_onReturnedHome),
    );
  }

  /// After any pop back to Home (Home control or system back), land on chats
  /// and retarget the gadgets manager to account / universal gadgets only.
  void _onReturnedHome() {
    if (!mounted) return;
    setState(() => _mobileTab = HomeMobileTab.chats);
    GadgetsScope.maybeOf(context)?.attach();
  }

  /// Workspace Home: pop every route above the feed. Home stays the first
  /// route — never push or replace it.
  void _popToHome() {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
  }

  void _setWorkspace(String name) => setState(() => _workspace = name);

  @override
  Widget build(BuildContext context) {
    // Home is always the shell body (navigator root). Workspaces are pushed
    // on top and popped away; this feed is never replaced.
    return SearchFeedScreen(
      key: ValueKey('search-feed-$_workspace-$_mobileTab'),
      dependencies: widget.dependencies,
      workspace: _workspace,
      onOpenWorkspace: (name) => _openWorkspace(name),
      onOpenSpaceRoom: _openWorkspaceRoom,
      initialMobileTab: _mobileTab,
    );
  }
}
