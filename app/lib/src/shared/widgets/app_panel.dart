import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import 'glass_surface.dart';

class AppPanel extends StatelessWidget {
  const AppPanel(
      {super.key,
      required this.title,
      required this.child,
      this.action,
      this.embedded = false});
  final String title;
  final Widget child;
  final Widget? action;

  /// When true the panel body stays clear so a host sheet paints the glass.
  final bool embedded;

  @override
  Widget build(BuildContext context) => GlassSurface(
        embedded: embedded,
        borderRadius: BorderRadius.circular(AppShape.inner),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
        ),
      );
}
