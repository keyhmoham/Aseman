import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_chrome.dart';

class AppBrand extends StatelessWidget {
  const AppBrand({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cyan = AppColors.cyanOf(context);
    final size = compact ? 27.0 : 34.0;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: context.chipRecipe.borderRadius,
          gradient: LinearGradient(
            colors: [cyan, scheme.primary],
          ),
        ),
        child: Icon(
          Icons.bolt_rounded,
          size: compact ? 18 : 20,
          color: scheme.onPrimary,
        ),
      ),
      const SizedBox(width: 10),
      Flexible(
          child: Text('aseman',
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                  fontSize: compact ? 17 : 21,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.6,
                  color: scheme.onSurface))),
    ]);
  }
}
