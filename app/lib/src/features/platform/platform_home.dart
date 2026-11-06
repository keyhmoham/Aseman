import 'dart:async';

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
///
/// Opening it (and bringing the client back to the foreground) wakes the
/// platform's computer first, through the frontend's `_aseman/wake`: it may
/// be asleep, and waking it is for whoever opens the platform, anywhere.
class PlatformHome extends StatefulWidget {
  const PlatformHome({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<PlatformHome> createState() => _PlatformHomeState();
}

class _PlatformHomeState extends State<PlatformHome>
    with WidgetsBindingObserver {
  PlatformInfo? _info;
  Object? _error;
  bool _loading = true;

  /// Waking the platform's computer: under way, and whether it answered.
  Future<bool>? _waking;
  bool _awake = false;
  DateTime? _awakeAt;
  String _wakeError = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back in front: the computer may have slept meanwhile.
    if (state == AppLifecycleState.resumed && _info?.frontend != null) {
      unawaited(_ensureAwake());
    }
  }

  /// Wakes the platform's computer unless it answered a moment ago ([force]:
  /// the frontend just said it is asleep). One wake at a time.
  Future<bool> _ensureAwake({bool force = false}) {
    final at = _awakeAt;
    if (!force &&
        _awake &&
        at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 60)) {
      return Future.value(true);
    }
    return _waking ??= _wake().whenComplete(() => _waking = null);
  }

  Future<bool> _wake() async {
    final slug = _info?.slug ?? PlatformMode.slug;
    final started = DateTime.now();
    var failures = 0;
    while (mounted) {
      try {
        final w = await widget.dependencies.service.platformWake(slug);
        if (w['ready'] == true) {
          if (mounted) {
            setState(() {
              _awake = true;
              _awakeAt = DateTime.now();
              _wakeError = '';
            });
          }
          return true;
        }
        if (w['state'] == 'failed') {
          if (mounted) {
            setState(() => _wakeError = '${w['error'] ?? 'unknown error'}');
          }
          return false;
        }
        failures = 0;
        final ms = (w['retry_after_ms'] as num?)?.toInt() ?? 2000;
        await Future<void>.delayed(
            Duration(milliseconds: ms.clamp(500, 10000)));
      } catch (e) {
        if (++failures >= 5) {
          if (mounted) setState(() => _wakeError = '$e');
          return false;
        }
        await Future<void>.delayed(Duration(seconds: 2 * failures));
      }
      if (DateTime.now().difference(started) > const Duration(minutes: 6)) {
        if (mounted) {
          setState(() => _wakeError = 'it is taking too long to wake up');
        }
        return false;
      }
    }
    return false;
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
        _wakeError = '';
      });
      if (info.frontend != null) unawaited(_ensureAwake(force: true));
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

  /// While the platform's computer wakes (or when it could not).
  Widget _wakingScreen(PlatformInfo info) {
    final theme = Theme.of(context);
    final failed = _wakeError.isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (failed)
                Icon(Icons.power_off_rounded,
                    size: 48, color: theme.colorScheme.onSurfaceVariant)
              else
                const SizedBox.square(
                    dimension: 40, child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Text(info.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                  failed
                      ? 'Could not wake up: $_wakeError'
                      : 'Waking up… this takes a moment the first time.',
                  textAlign: TextAlign.center),
              if (failed) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                    onPressed: () {
                      setState(() => _wakeError = '');
                      _ensureAwake(force: true);
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again')),
                TextButton(onPressed: _signOut, child: const Text('Sign out')),
              ],
            ]),
          ),
        ),
      ),
    );
  }

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
    if (!_awake) return _wakingScreen(info);
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
                    onAsleep: () => _ensureAwake(force: true),
                  ),
          ),
          Positioned(top: 4, right: 4, child: _menu()),
        ]),
      ),
    );
  }
}
