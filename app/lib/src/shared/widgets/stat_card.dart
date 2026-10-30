import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import 'glass_surface.dart';

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
  Widget build(BuildContext context) => GlassSurface(
        borderRadius: BorderRadius.circular(AppShape.inner),
        child: Container(
          constraints: const BoxConstraints(minWidth: 180),
          padding: const EdgeInsets.all(17),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12)),
            const SizedBox(height: 9),
            Text(value,
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            Text(change,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}
