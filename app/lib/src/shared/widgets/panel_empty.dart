import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import 'sky_ui.dart';

/// Soft empty state for modal panels and tab lists: a [SkyIconBadge],
/// a short headline, and one supporting line. Cheap to paint (no blur).
///
/// Pass [compact] for side rails and narrow panes (smaller badge + type).
class PanelEmpty extends StatelessWidget {
  const PanelEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.compact = false,
    this.accent,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool compact;

  /// Optional badge accent; defaults to the scheme primary.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badge = compact ? 40.0 : 56.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? AppSpacing.md : AppSpacing.xl - 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SkyIconBadge(
            icon: icon,
            size: badge,
            accent: accent ?? scheme.primary,
            secondary: scheme.tertiary,
          ),
          SizedBox(height: compact ? AppSpacing.sm - 2 : AppSpacing.md),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: compact ? 13 : 17,
                  letterSpacing: -.3,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface)),
          SizedBox(height: compact ? AppSpacing.xxs : AppSpacing.xs - 2),
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: compact ? 11 : 13,
                  height: 1.35,
                  color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
