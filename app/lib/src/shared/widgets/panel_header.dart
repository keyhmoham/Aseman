import 'package:flutter/material.dart';

/// Responsive header for the app's modal panels. On wide screens the icon +
/// title + subtitle sit on one line with the actions beside them; on narrow
/// screens the title row stays on top and the actions wrap below, so nothing
/// gets squeezed or clipped on mobile bottom sheets.
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
    // An expressive header: the icon sits in a tonal rounded square beside
    // a bold title, the same as the admin console's page headers.
    final heading = Row(children: [
      Container(
        width: 48,
        height: 48,
        decoration: ShapeDecoration(
          color: scheme.primaryContainer,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Icon(icon, size: 24, color: scheme.onPrimaryContainer),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 26,
                  height: 1.15,
                  letterSpacing: -.5,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ]),
      ),
    ]);

    return LayoutBuilder(builder: (context, box) {
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
