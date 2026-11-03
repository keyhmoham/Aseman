import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import 'sky_ui.dart';

/// Wallet / KPI card: quiet pack surface, accent only on change text.
class StatCard extends StatelessWidget {
  const StatCard(
      {super.key,
      required this.title,
      required this.value,
      required this.change,
      required this.color});
  final String title;
  final String value;
  final String change;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftCard(
      radius: AppShape.inner,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        EyebrowLabel(title, color: scheme.onSurfaceVariant, size: 10),
        const SizedBox(height: 6),
        Text(value,
            style: TextStyle(
                fontSize: 24,
                letterSpacing: -.4,
                height: 1.1,
                fontWeight: FontWeight.w900,
                color: scheme.onSurface)),
        const SizedBox(height: 5),
        Text(change,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
