import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../home/presentation/workspace_screen.dart';
import '../../search_feed/presentation/search_feed_screen.dart';

/// Root shell: the search feed (Pulse) is the landing page after login.
/// Picking a workspace from the app bar opens that workspace's home desk;
/// the profile avatar in the app bar opens the profile menu (profile, my
/// bots, market, wallet, settings).
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.dependencies});
  final AppDependencies dependencies;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String _workspace = 'Home';
  int _page = 0; // 0 = search feed, 1 = workspace desk

  void _openWorkspace(String name) {
    setState(() {
      _workspace = name;
      _page = 1;
    });
  }

  void _openFeed() => setState(() => _page = 0);

  void _setWorkspace(String name) => setState(() => _workspace = name);

  @override
  Widget build(BuildContext context) {
    final feed = SearchFeedScreen(
      key: ValueKey('search-feed-$_workspace'),
      dependencies: widget.dependencies,
      workspace: _workspace,
      onOpenWorkspace: _openWorkspace,
    );
    final desk = WorkspaceScreen(
      key: const ValueKey('workspace-desk'),
      dependencies: widget.dependencies,
      initialWorkspace: _workspace,
      onBackToFeed: _openFeed,
      onWorkspaceChanged: _setWorkspace,
    );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: .985, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: _page == 0 ? feed : desk,
    );
  }
}
