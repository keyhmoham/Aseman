import 'dart:async';
import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_surfaces.dart';
import '../../core/theme/theme_chrome.dart';
import '../../shared/widgets/glass_surface.dart';
import '../messenger/presentation/chat_page.dart';
import 'brain_avatar.dart';

/// Opens the personal Aseman chat (self chat) using the messenger panel flow.
Future<void> openSavedMessages(
  BuildContext context,
  AppDependencies dependencies,
) async {
  try {
    final chat = await dependencies.service.openSaved();
    if (!context.mounted) return;
    await showChat(context, dependencies, chat);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open Aseman: $e')),
    );
  }
}

/// Opens the personal Aseman chat shell (Desk | Chat). Kept for callers that
/// still name "brain sheet"; the overlay note/voice sheet is no longer the
/// primary entry.
Future<void> showBrainSheet(
  BuildContext context,
  AppDependencies dependencies,
) =>
    openSavedMessages(context, dependencies);

/// Circular glass shortcut used beside [HomeTabBar] / on desktop.
class AsemanBrainButton extends StatelessWidget {
  const AsemanBrainButton({
    super.key,
    required this.dependencies,
    this.size = 52,
    this.chip = false,
  });

  final AppDependencies dependencies;
  final double size;

  /// Wider labeled chip for desktop header / lower-right.
  final bool chip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent =
        AppSettingsScope.maybeOf(context)?.accent ?? scheme.primary;

    void open() => openSavedMessages(context, dependencies);

    if (chip) {
      final fab = context.fabRecipe;
      final shell = ThemeChrome.floatingShell(context, lift: 2);
      final radius = fab.borderRadius;
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: shell.boxShadow,
        ),
        child: GlassSurface(
          alpha: AppSurfaces.overlayAlphaOf(context),
          blur: AppSurfaces.blurSigmaOf(context),
          borderRadius: radius,
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MiniMark(accent: accent, size: 28),
                const SizedBox(width: 8),
                Text(
                  'Aseman',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final shell = ThemeChrome.floatingShell(context, lift: 2);
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: shell.boxShadow,
      ),
      child: GlassSurface(
        alpha: AppSurfaces.overlayAlphaOf(context),
        blur: AppSurfaces.blurSigmaOf(context),
        borderRadius: context.fabRecipe.borderRadius,
        onTap: open,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: _MiniMark(accent: accent, size: size * .62)),
        ),
      ),
    );
  }
}

class _MiniMark extends StatelessWidget {
  const _MiniMark({required this.accent, required this.size});
  final Color accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    return BrainAvatar(
      prefs: const BrainAvatarPrefs(),
      accent: accent,
      size: size,
    );
  }
}
