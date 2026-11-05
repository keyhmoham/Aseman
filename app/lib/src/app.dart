import 'dart:async';

import 'package:flutter/material.dart';

import 'app_dependencies.dart';
import 'core/platform/platform_mode.dart';
import 'core/settings/app_settings.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/halo_ring_cache.dart';
import 'core/theme/theme_pack_controller.dart';
import 'core/theme/theme_runtime_scope.dart';
import 'features/auth/presentation/auth_screen.dart';
import 'features/calls/call_overlay.dart';
import 'features/gadgets/presentation/gadgets_overlay.dart';
import 'features/navigation/presentation/app_shell.dart';
import 'features/platform/platform_home.dart';

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
  final themePacks = ThemePackController();

  @override
  void initState() {
    super.initState();
    // Hold the first frame until the cached theme is applied, so a saved
    // light or dark choice does not flash the default on startup.
    WidgetsBinding.instance.deferFirstFrame();
    themePacks.addListener(_onThemePackChanged);
    unawaited(_restoreTheme());
  }

  void _onThemePackChanged() {
    settings.syncPaletteToPack(themePacks.pack);
  }

  Future<void> _restoreTheme() async {
    try {
      await Future.wait([
        settings.restore(),
        themePacks.restore(),
        HaloRingCache.restore(),
      ]);
      // Drop orphan palette ids after a pack swap or store install.
      settings.syncPaletteToPack(themePacks.pack);
    } finally {
      WidgetsBinding.instance.allowFirstFrame();
    }
  }

  @override
  void dispose() {
    themePacks.removeListener(_onThemePackChanged);
    settings.dispose();
    themePacks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([settings, themePacks]),
        builder: (context, _) => AppSettingsScope(
          controller: settings,
          child: ThemePackScope(
            controller: themePacks,
            child: MaterialApp(
              navigatorKey: AsemanApp.navigatorKey,
              debugShowCheckedModeBanner: false,
              title: PlatformMode.active ? PlatformMode.slug : 'Aseman',
              theme: AppTheme.lightWith(
                settings.accent,
                pack: themePacks.pack,
                paletteId: settings.paletteId,
              ),
              darkTheme: AppTheme.darkWith(
                settings.accent,
                pack: themePacks.pack,
                paletteId: settings.paletteId,
              ),
              themeMode: settings.themeMode,
              // Overlay above the navigator so the gadgets edge handle and
              // GadgetsScope cover home and every pushed workspace.
              builder: (context, child) => ThemeRuntimeScope(
                dependencies: widget.dependencies,
                child: AuthGate(
                  dependencies: widget.dependencies,
                  child: CallOverlay(
                    dependencies: widget.dependencies,
                    child: GadgetsOverlay(
                      dependencies: widget.dependencies,
                      navigatorKey: AsemanApp.navigatorKey,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              // A sub-platform's client opens on the platform's frontend.
              home: PlatformMode.active
                  ? PlatformHome(dependencies: widget.dependencies)
                  : AppShell(dependencies: widget.dependencies),
            ),
          ),
        ),
      );
}
