import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import 'sky_ui.dart';

/// Titled content block used in sidebars and feature pages.
///
/// Soft gradient surface (no nested backdrop blur) so stacks of panels stay
/// cheap to paint while matching the switcher / You-tab language.
class AppPanel extends StatelessWidget {
  const AppPanel(
      {super.key,
      required this.title,
      required this.child,
      this.action,
      this.embedded = false,
      this.icon,
      this.accent});
  final String title;
  final Widget child;
  final Widget? action;

  /// Kept for call-site compatibility; nested glass is no longer painted.
  final bool embedded;

  /// Optional leading glyph for section identity.
  final IconData? icon;

  /// Accent wash for the soft surface.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentColor = accent ?? scheme.primary;
    return SoftCard(
      accent: accentColor,
      secondary: scheme.tertiary,
      radius: AppShape.inner,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md - 1, AppSpacing.sm + 2, AppSpacing.md - 1, AppSpacing.md - 1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (icon != null) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                color: accentColor.withValues(alpha: .14),
              ),
              child: Icon(icon, size: 15, color: accentColor),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.2,
                    ) ??
                    const TextStyle(fontWeight: FontWeight.w800)),
          ),
          if (action != null) action!,
        ]),
        const SizedBox(height: AppSpacing.sm),
        DefaultTextStyle.merge(
          style: TextStyle(color: scheme.onSurface),
          child: child,
        ),
      ]),
    );
  }
}
