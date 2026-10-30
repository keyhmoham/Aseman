import 'package:flutter/material.dart';

/// Responsive header for the app's modal panels. On wide screens the icon +
/// title + subtitle sit on one line with the actions beside them; on narrow
/// screens the title row stays on top and the actions wrap below, so nothing
/// gets squeezed or clipped on mobile bottom sheets.
///
/// When the available width is rail-sized (< 380), the heading scales down so
/// side panels stay readable without oversized chrome.
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
    final scheme = Theme.of(context).colorScheme;
    final close = onClose == null
        ? null
        : IconButton.filledTonal(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded));

    return LayoutBuilder(builder: (context, box) {
      final rail = box.maxWidth < 380;
      final iconBox = rail ? 36.0 : 48.0;
      final iconSize = rail ? 18.0 : 24.0;
      final titleSize = rail ? 17.0 : 26.0;
      final heading = Row(children: [
        Container(
          width: iconBox,
          height: iconBox,
          decoration: ShapeDecoration(
            color: scheme.primaryContainer,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rail ? 12 : 16)),
          ),
          child: Icon(icon, size: iconSize, color: scheme.onPrimaryContainer),
        ),
        SizedBox(width: rail ? 10 : 14),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: titleSize,
                    height: 1.15,
                    letterSpacing: -.5,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(subtitle,
                maxLines: rail ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: rail ? 11 : 13,
                    color: scheme.onSurfaceVariant)),
          ]),
        ),
      ]);

      if (box.maxWidth >= 560) {
        return Row(children: [
          Expanded(child: heading),
          for (final a in actions) a,
          if (close != null) close,
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: heading),
          if (close != null) close,
        ]),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(spacing: 8, runSpacing: 8, children: actions),
          ),
        ],
      ]);
    });
  }
}
