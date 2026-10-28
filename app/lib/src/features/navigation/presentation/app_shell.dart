import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../assistant/assistant.dart';
import '../../home/presentation/workspace_screen.dart';
import '../../search_feed/presentation/rich_post_content.dart';
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

  @override
  void initState() {
    super.initState();
    // A post's author (or a shared post's original author) opens their
    // profile wherever the post shows.
    PostLinks.openAccount = (context, accountId, handle) => showAccountProfile(
        context, widget.dependencies,
        accountId: accountId, handle: handle);
    // On a desktop where the person let agents use this computer, keep
    // answering them.
    hostAgentFor(widget.dependencies).restore().ignore();
    _firstDay();
  }

  /// On a person's first day the lead greets them in their home chat and
  /// asks what they work on; the setup checklist then shows what is left.
  /// The node runs it once, however often this asks.
  Future<void> _firstDay() async {
    try {
      final out = await widget.dependencies.service
          .invokeAction('proactive', 'first_day');
      if (!mounted || out is! Map || out['started'] != true) return;
      await openPanel(context, SetupPanel(dependencies: widget.dependencies));
    } catch (_) {
      // No proactive work on this node.
    }
  }

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
    // Each page moves its own panels in and out, like a workspace switch,
    // so the shell swaps them without a transition of its own.
    return _page == 0 ? feed : desk;
  }
}
