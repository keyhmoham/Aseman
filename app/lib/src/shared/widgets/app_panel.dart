import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

class AppPanel extends StatelessWidget {
  const AppPanel(
      {super.key, required this.title, required this.child, this.action});
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            action ??
                const Icon(Icons.more_horiz_rounded,
                    color: AppColors.muted, size: 19),
          ]),
          const SizedBox(height: 13),
          child,
        ]),
      );
}
