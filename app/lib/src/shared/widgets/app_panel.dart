import 'package:flutter/material.dart';

import '../../core/theme/app_surfaces.dart';

class AppPanel extends StatelessWidget {
  const AppPanel(
      {super.key, required this.title, required this.child, this.action});
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: AppSurfaces.cardDecoration(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            action ??
                Icon(Icons.more_horiz_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 19),
          ]),
          const SizedBox(height: 13),
          child,
        ]),
      );
}
