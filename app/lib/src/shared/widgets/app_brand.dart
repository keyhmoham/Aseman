import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

class AppBrand extends StatelessWidget {
  const AppBrand({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: compact ? 27 : 34,
          height: compact ? 27 : 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: const LinearGradient(
                colors: [AppColors.cyan, Color(0xFF3756E8)]),
          ),
          child: const Icon(Icons.bolt_rounded, size: 20),
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
                    letterSpacing: -.6))),
      ]);
}
