import 'package:flutter/material.dart';

import 'app_dependencies.dart';
import 'core/settings/app_settings.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_screen.dart';
import 'features/navigation/presentation/app_shell.dart';

class TraderaApp extends StatefulWidget {
  const TraderaApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<TraderaApp> createState() => _TraderaAppState();
}

class _TraderaAppState extends State<TraderaApp> {
  final settings = AppSettingsController();
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
            debugShowCheckedModeBanner: false,
            title: 'Tradera',
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
