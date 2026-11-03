import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/sky_ui.dart';

/// A tool's mark: an icon that fits its name, on a tonal well whose hue is
/// derived from the **active pack palette** (stable per tool id).
class ToolAvatar extends StatelessWidget {
  const ToolAvatar({
    super.key,
    required this.tool,
    required this.name,
    this.size = 36,
    this.selected = false,
  });

  final String tool;
  final String name;
  final double size;

  /// Filled with the tool's strong color, the shape squarer (M3 expressive
  /// selection: color and shape change together).
  final bool selected;

  /// The pictures the tools were given, by tool (bot) id, as the workspace's
  /// bots were last loaded. A tool with one shows it over its icon.
  static final ValueNotifier<Map<String, String>> pictures =
      ValueNotifier(const {});

  /// Records the pictures of [avatars] (bot id → picture), keeping others.
  static void remember(Map<String, String> avatars) {
    final next = {...pictures.value};
    avatars.forEach((id, avatar) {
      if (avatar.isEmpty) {
        next.remove(id);
      } else {
        next[id] = avatar;
      }
    });
    if (!mapEquals(next, pictures.value)) pictures.value = next;
  }

  /// Pack-aware accent for [tool] (replaces the old private seed palette).
  static Color accentFor(BuildContext context, String tool) =>
      ThemeRoles.identity(context, tool);

  /// Legacy helper for call sites without a [BuildContext]. Prefer [accentFor].
  /// Uses a neutral seed — decorative tool colour comes from [accentFor].
  static ColorScheme schemeFor(String tool, Brightness brightness) =>
      ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: brightness,
      );

  static IconData iconFor(String name) {
    final n = name.toLowerCase();
    bool has(List<String> words) => words.any(n.contains);
    if (n == 'widgets') return Icons.dashboard_customize_rounded;
    if (n == 'web pages') return Icons.language_rounded;
    if (n == 'files') return Icons.folder_copy_rounded;
    if (n == 'computer') return Icons.desktop_windows_rounded;
    if (has(['weather', 'forecast', 'climate'])) return Icons.wb_sunny_rounded;
    if (has(['market', 'store', 'catalog', 'listing'])) {
      return Icons.storefront_rounded;
    }
    if (has(['wallet', 'bank', 'finance', 'billing'])) {
      return Icons.account_balance_wallet_rounded;
    }
    if (has(['chart', 'analytic', 'stats', 'metric', 'dashboard'])) {
      return Icons.insights_rounded;
    }
    if (has(['news', 'feed', 'rss'])) return Icons.newspaper_rounded;
    if (has(['map', 'geo', 'place', 'location'])) return Icons.map_rounded;
    if (has(['calendar', 'event', 'schedule'])) return Icons.event_rounded;
    if (has(['mail', 'email', 'inbox'])) return Icons.mail_rounded;
    if (has(['git', 'code', 'repo', 'wiki', 'dev'])) return Icons.code_rounded;
    if (has(['search', 'find'])) return Icons.travel_explore_rounded;
    if (has(['note', 'doc', 'file', 'drive'])) return Icons.description_rounded;
    if (has(['music', 'audio', 'sound'])) return Icons.music_note_rounded;
    if (has(['image', 'photo', 'video'])) return Icons.photo_library_rounded;
    if (has(['chat', 'message', 'slack'])) return Icons.forum_rounded;
    if (has(['sandbox', 'terminal', 'shell'])) return Icons.terminal_rounded;
    if (has(['translate', 'language'])) return Icons.translate_rounded;
    return Icons.widgets_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final ambient = Theme.of(context).colorScheme;
    final accent = accentFor(context, tool);
    final corners = context.avatarBorderRadius(size);
    final well = selected
        ? accent
        : Color.alphaBlend(accent.withValues(alpha: .16), ambient.surface);
    final ink = selected ? ambient.onPrimary : accent;
    final mark = AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: well,
        borderRadius: corners,
      ),
      child: Icon(iconFor(name), size: size * .54, color: ink),
    );
    return HaloRing(
      accent: accent,
      borderRadius: corners,
      child: ValueListenableBuilder<Map<String, String>>(
        valueListenable: pictures,
        builder: (context, avatars, _) => AvatarPicture(
            avatar: avatars[tool],
            size: size,
            borderRadius: corners,
            fallback: mark),
      ),
    );
  }
}
