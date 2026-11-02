import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import 'sky_ui.dart';

/// Slim metric cell used across account, settings, and panel strips:
/// quiet label, large value, optional live accent. Soft surface, no blur.
class FleetMetric extends StatelessWidget {
  const FleetMetric({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.color,
    this.live = false,
  });

  final String label;
  final String value;
  final String? hint;
  final Color? color;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    return SoftCard(
      accent: accent,
      radius: AppShape.control,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        EyebrowLabel(label, color: accent.withValues(alpha: .9), size: 9.5),
        const SizedBox(height: 3),
        Row(children: [
          Flexible(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 20,
                    height: 1.1,
                    letterSpacing: -.4,
                    fontWeight: FontWeight.w900,
                    color: live ? accent : null)),
          ),
          if (live) ...[
            const SizedBox(width: 8),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent,
                boxShadow: [
                  BoxShadow(
                      color: accent.withValues(alpha: .45),
                      blurRadius: 6,
                      spreadRadius: .5),
                ],
              ),
            ),
          ],
        ]),
        if (hint != null && hint!.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color ?? scheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

/// Horizontal row of [FleetMetric] cells that share remaining width.
class FleetMetricStrip extends StatelessWidget {
  const FleetMetricStrip({super.key, required this.cells, this.gap = 10});

  final List<FleetMetric> cells;
  final double gap;

  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < cells.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(child: cells[i]),
        ],
      ]);
}
