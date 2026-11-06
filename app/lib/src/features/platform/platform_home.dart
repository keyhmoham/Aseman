import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/platform/platform_mode.dart';
import '../../shared/widgets/skeleton.dart';
import '../desk/presentation/web_page_view.dart';
import '../navigation/presentation/app_shell.dart';
import '../tools/elpian_app/elpian_app_view.dart';

/// Home of a platform's client ([PlatformMode]): the frontend the
/// platform's organization published — an app the agents of a space built —
/// full screen, as the signed-in person of the platform. An Elpian frontend
/// runs natively; a web one in a web view. Its backend uses that space's
/// agents and apps for them. A platform with no frontend yet gets the regular
/// workspace; the menu reaches the workspace and signs out either way.
class PlatformHome extends StatefulWidget {
  const PlatformHome({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<PlatformHome> createState() => _PlatformHomeState();
}

class _PlatformHomeState extends State<PlatformHome> {
  PlatformInfo? _info;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await widget.dependencies.service.platformInfo();
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _openWorkspace() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AppShell(dependencies: widget.dependencies),
    ));
  }

  Future<void> _signOut() => widget.dependencies.sessionController.logout();

  Widget _menu() => PopupMenuButton<String>(
        key: const ValueKey('platform-menu'),
        tooltip: 'Menu',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (choice) {
          switch (choice) {
            case 'reload':
              _load();
            case 'workspace':
              _openWorkspace();
            case 'signout':
              _signOut();
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
              value: 'reload',
              child: ListTile(
                  leading: Icon(Icons.refresh_rounded), title: Text('Reload'))),
          PopupMenuItem(
              value: 'workspace',
              child: ListTile(
                  leading: Icon(Icons.dashboard_outlined),
                  title: Text('Workspace'))),
          PopupMenuItem(
              value: 'signout',
              child: ListTile(
                  leading: Icon(Icons.logout_rounded),
                  title: Text('Sign out'))),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: SafeArea(child: SkeletonPage()));
    }
    final info = _info;
    if (_error != null || info == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.cloud_off_rounded,
                    size: 48,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('This platform could not be reached',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('$_error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again')),
                TextButton(onPressed: _signOut, child: const Text('Sign out')),
              ]),
            ),
          ),
        ),
      );
    }
    final frontend = info.frontend;
    if (frontend == null) {
      // Nothing published yet: the platform's regular workspace.
      return AppShell(dependencies: widget.dependencies);
    }
    final service = widget.dependencies.service;
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: frontend.isWeb
                ? WebPageView(
                    key: ValueKey('platform-web-${frontend.url}'),
                    service: service,
                    page: frontend.url,
                    embed: 'screen',
                    showStrip: false,
                  )
                : ElpianAppView(
                    key: ValueKey('platform-elpian-${frontend.url}'),
                    service: service,
                    page: frontend.url,
                    entry: frontend.entry,
                    title: frontend.title,
                  ),
          ),
          Positioned(top: 4, right: 4, child: _menu()),
        ]),
      ),
    );
  }
}
