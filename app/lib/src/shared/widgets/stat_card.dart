import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

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
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 180),
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 9),
          Text(value,
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(change,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}
