import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import 'sky_ui.dart';

/// Wallet / KPI card aligned with [FleetMetric]: quiet label, large value,
/// optional tinted hint. Soft gradient surface matching the You-tab language.
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
    return SoftCard(
      accent: color,
      radius: AppShape.inner,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        EyebrowLabel(title, color: color, size: 10),
        const SizedBox(height: 6),
        Text(value,
            style: const TextStyle(
                fontSize: 24,
                letterSpacing: -.4,
                height: 1.1,
                fontWeight: FontWeight.w900)),
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
