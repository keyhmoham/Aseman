import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../src/core/theme/app_theme.dart';
import 'account_sheet.dart';
import 'frontend_view.dart';
import 'node_api.dart';
import 'wake.dart';

/// The lightweight client of one platform: its published Elpian frontend,
/// full screen, and nothing else of Aseman. Opening it (or bringing it back)
/// wakes the platform's computer wherever the phone is.
class PlatformClientApp extends StatelessWidget {
  const PlatformClientApp({super.key, required this.api, required this.wake});

  final NodeApi api;
  final WakeController wake;

  @override
  Widget build(BuildContext context) {
    final accent = api.config.accent;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: api.config.name,
      theme: accent == null ? AppTheme.light : AppTheme.lightWith(Color(accent)),
      darkTheme: accent == null ? AppTheme.dark : AppTheme.darkWith(Color(accent)),
      home: PlatformScreen(api: api, wake: wake),
    );
  }
}

/// Wakes the platform, then shows its frontend.
class PlatformScreen extends StatefulWidget {
  const PlatformScreen({super.key, required this.api, required this.wake});

  final NodeApi api;
  final WakeController wake;

  @override
  State<PlatformScreen> createState() => _PlatformScreenState();
}

class _PlatformScreenState extends State<PlatformScreen> with WidgetsBindingObserver {
  PlatformInfo? _info;
  Object? _infoError;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.wake.addListener(_changed);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.wake.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back in front: the computer may have slept meanwhile.
    if (state == AppLifecycleState.resumed) widget.wake.ensureAwake();
  }

  Future<void> _start() async {
    setState(() => _infoError = null);
    try {
      final info = await widget.api.platformInfo();
      if (!mounted) return;
      setState(() => _info = info);
      if (info.published) await widget.wake.ensureAwake(force: true);
    } catch (e) {
      if (mounted) setState(() => _infoError = e);
    }
  }

  void _reload() {
    setState(() => _generation++);
    _start();
  }

  Future<void> _account() async {
    final api = widget.api;
    if (api.session != null) {
      await api.signOut();
    } else if (!await showAccountSheet(context, api, _info?.name ?? api.config.name)) {
      return;
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final wake = widget.wake;
    final name = info?.name ?? widget.api.config.name;
    Widget body;
    if (_infoError != null) {
      body = _Message(
          icon: Icons.cloud_off_rounded,
          title: '$name could not be reached',
          detail: '$_infoError',
          action: 'Try again',
          onAction: _reload);
    } else if (info == null) {
      body = _Waking(name: name, detail: 'Connecting…');
    } else if (!info.published) {
      body = _Message(
          icon: Icons.hourglass_empty_rounded,
          title: '$name is not open yet',
          detail: 'Its app has not been published. Try again later.',
          action: 'Reload',
          onAction: _reload);
    } else if (!info.isElpian) {
      body = _Message(
          icon: Icons.open_in_browser_rounded,
          title: name,
          detail: '$name opens in the browser.',
          action: 'Open',
          onAction: () => launchUrl(Uri.parse(widget.api.config.frontendUrl), mode: LaunchMode.externalApplication));
    } else if (!wake.everReady) {
      body = wake.phase == WakePhase.failed
          ? _Message(
              icon: Icons.power_off_rounded,
              title: '$name could not wake up',
              detail: wake.error,
              action: 'Try again',
              onAction: () => wake.ensureAwake(force: true))
          : _Waking(name: name, detail: 'Waking up… this takes a moment the first time.');
    } else {
      body = Stack(children: [
        Positioned.fill(
          child: FrontendView(
              key: ValueKey('frontend-$_generation'), api: widget.api, wake: wake, platform: info),
        ),
        if (wake.phase == WakePhase.waking)
          const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 3)),
        Positioned(top: 4, right: 4, child: _menu()),
      ]);
    }
    return Scaffold(body: SafeArea(child: body));
  }

  Widget _menu() {
    final signedIn = widget.api.session != null;
    return PopupMenuButton<String>(
      key: const ValueKey('platform-menu'),
      tooltip: 'Menu',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (choice) => choice == 'reload' ? _reload() : _account(),
      itemBuilder: (_) => [
        const PopupMenuItem(
            value: 'reload', child: ListTile(leading: Icon(Icons.refresh_rounded), title: Text('Reload'))),
        PopupMenuItem(
          value: 'account',
          child: ListTile(
            leading: Icon(signedIn ? Icons.logout_rounded : Icons.login_rounded),
            title: Text(signedIn ? 'Sign out @${widget.api.session!.handle}' : 'Sign in'),
          ),
        ),
      ],
    );
  }
}

class _Waking extends StatelessWidget {
  const _Waking({required this.name, required this.detail});

  final String name;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox.square(dimension: 40, child: CircularProgressIndicator()),
          const SizedBox(height: 20),
          Text(name, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    required this.action,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(detail, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: onAction, icon: const Icon(Icons.refresh_rounded), label: Text(action)),
        ]),
      ),
    );
  }
}
