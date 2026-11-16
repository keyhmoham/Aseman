import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'aseman_tokens.dart';
import 'default_theme_packs.dart';
import 'theme_pack.dart';

/// Pack-aware colour roles for widgets that used to hardcode Material Accents
/// or Sky literals. Prefer these over `Colors.green` / `AppColors.primary`.
///
/// Decorative accents follow the selected palette (unified by default). Status
/// colours (success / warning / danger) stay semantic.
abstract final class ThemeRoles {
  static AsemanTokens? _tokens(BuildContext context) =>
      AsemanTokens.maybeOf(context);

  /// Accent for a named UI part (falls back to the palette accent).
  static Color partAccent(BuildContext context, ThemePartId part) {
    final tokens = _tokens(context);
    if (tokens != null) return tokens.partAccent(part);
    return Theme.of(context).colorScheme.primary;
  }

  /// Secondary for a named UI part (unified packs reuse the accent).
  static Color partSecondary(BuildContext context, ThemePartId part) {
    final tokens = _tokens(context);
    if (tokens != null) return tokens.partSecondary(part);
    return Theme.of(context).colorScheme.primary;
  }

  /// Identity / hash accents — a single brand colour when unified.
  static List<Color> identityPool(BuildContext context) =>
      [partAccent(context, ThemePartId.identity)];

  /// Stable accent for [key]. Unified packs always return the identity accent
  /// (one colour for every mark); non-unified packs still use that single
  /// identity override rather than a rainbow.
  static Color identity(BuildContext context, String key) =>
      partAccent(context, ThemePartId.identity);

  /// Status / health colour from pack tokens.
  static Color status(BuildContext context, String status) {
    final s = status.toLowerCase();
    if (s.contains('error') ||
        s.contains('fail') ||
        s.contains('danger') ||
        s.contains('offline') ||
        s.contains('dead')) {
      return AppColors.dangerOf(context);
    }
    if (s.contains('warn') || s.contains('pending') || s.contains('busy')) {
      return AppColors.warningOf(context);
    }
    if (s.contains('ok') ||
        s.contains('ready') ||
        s.contains('live') ||
        s.contains('success') ||
        s.contains('online') ||
        s.contains('active')) {
      return AppColors.successOf(context);
    }
    if (s.contains('info') || s.contains('cyan') || s.contains('secondary')) {
      return partAccent(context, ThemePartId.links);
    }
    return Theme.of(context).colorScheme.primary;
  }

  /// Selected-row fill. Paper uses the accent's secondary container tone.
  static Color selectedFill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_tokens(context)?.packId == DefaultThemePacks.paperId) {
      return scheme.secondaryContainer;
    }
    final accent = partAccent(context, ThemePartId.selection);
    return Color.alphaBlend(
      accent.withValues(alpha: .10),
      scheme.surface,
    );
  }

  /// Ink drawn on [selectedFill] (icons, labels).
  static Color selectedInk(BuildContext context) {
    if (_tokens(context)?.packId == DefaultThemePacks.paperId) {
      return Theme.of(context).colorScheme.onSecondaryContainer;
    }
    return partAccent(context, ThemePartId.selection);
  }

  /// Neutral icon / empty-state well (pack surface, not a container wash).
  static Color wellFill(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHighest;

  /// Ink for [wellFill].
  static Color wellInk(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  /// Highlighted bubble. Paper uses the accent's primary container tone.
  static Color bubbleFill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_tokens(context)?.packId == DefaultThemePacks.paperId) {
      return scheme.primaryContainer;
    }
    final accent = partAccent(context, ThemePartId.bubbles);
    return Color.alphaBlend(
      accent.withValues(alpha: .12),
      scheme.surface,
    );
  }
}
