import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import 'sky_ui.dart';

/// Responsive header for the app's modal panels. On wide screens the icon +
/// title + subtitle sit on one line with the actions beside them; on narrow
/// screens the title row stays on top and the actions wrap below, so nothing
/// gets squeezed or clipped on mobile bottom sheets.
///
/// Uses the shared sky badge (circular primary→cyan gradient) so every panel
/// matches the workspace switcher / You tab voice.
class PanelHeader extends StatelessWidget {
  const PanelHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actions = const [],
    this.onClose,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final rail = box.maxWidth < 380;
      final heading = SkySectionHeader(
        icon: icon,
        title: title,
        subtitle: subtitle,
        dense: rail,
        onClose: box.maxWidth < 560 ? onClose : null,
      );

      final actionRow = [
        for (final a in actions) ...[
          a,
          if (a != actions.last) const SizedBox(width: AppSpacing.xs),
        ],
        if (box.maxWidth >= 560 && onClose != null) ...[
          if (actions.isNotEmpty) const SizedBox(width: AppSpacing.xs),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: .45),
            ),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ];

      if (box.maxWidth >= 560) {
        return Row(children: [
          Expanded(
            child: SkySectionHeader(
              icon: icon,
              title: title,
              subtitle: subtitle,
              dense: false,
            ),
          ),
          ...actionRow,
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        heading,
        if (actions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: actions),
          ),
        ],
      ]);
    });
  }
}
