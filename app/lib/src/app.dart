import 'dart:async';

import 'package:flutter/material.dart';

import 'app_dependencies.dart';
import 'core/settings/app_settings.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_screen.dart';
import 'features/navigation/presentation/app_shell.dart';

class AsemanApp extends StatefulWidget {
  const AsemanApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  /// The app's navigator, for prompts raised outside any screen (the
  /// desktop host agent's confirmations).
  static final navigatorKey = GlobalKey<NavigatorState>();

  @override
  State<AsemanApp> createState() => _AsemanAppState();
}

class _AsemanAppState extends State<AsemanApp> {
  final settings = AppSettingsController();

  @override
  void initState() {
    super.initState();
    // Hold the first frame until the cached theme is applied, so a saved
    // light or dark choice does not flash the default on startup.
    WidgetsBinding.instance.deferFirstFrame();
    unawaited(_restoreTheme());
  }

  Future<void> _restoreTheme() async {
    try {
      await settings.restore();
    } finally {
      WidgetsBinding.instance.allowFirstFrame();
    }
  }

  @override
  void dispose() {
    settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: settings,
    builder: (context, _) => AppSettingsScope(
      controller: settings,
      child: MaterialApp(
        navigatorKey: AsemanApp.navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'Aseman',
        theme: AppTheme.lightWith(settings.accent),
        darkTheme: AppTheme.darkWith(settings.accent),
        themeMode: settings.themeMode,
        home: AuthGate(
          dependencies: widget.dependencies,
          child: AppShell(dependencies: widget.dependencies),
        ),
      ),
    ),
  );
}
