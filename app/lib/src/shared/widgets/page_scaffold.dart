import 'package:flutter/material.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/theme/app_colors.dart';
import 'app_brand.dart';
import 'avatar.dart';

class FeaturePage extends StatelessWidget {
  const FeaturePage(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.child,
      this.actions = const [],
      this.onBack});
  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  /// When provided, a back button is shown so pushed pages can return.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.compact;
    final heading = _Heading(title, subtitle);
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              compact ? 18 : 30, compact ? 16 : 26, compact ? 18 : 30, 18),
          child: compact
              ? Row(children: [
                  if (onBack != null) ...[
                    IconButton(
                        onPressed: onBack,
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back_rounded)),
                  ] else ...[
                    const AppBrand(compact: true),
                  ],
                  const Spacer(),
                  const Icon(Icons.search_rounded),
                  const SizedBox(width: 16),
                  const AppAvatar('AC', color: AppColors.primary),
                ])
              : Row(children: [
                  if (onBack != null) ...[
                    IconButton(
                        onPressed: onBack,
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back_rounded)),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: heading),
                  ...actions
                ]),
        ),
        if (compact)
          Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              child: Align(alignment: Alignment.centerLeft, child: heading)),
        Expanded(child: child),
      ]),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, this.subtitle);
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(
                fontSize: 27, fontWeight: FontWeight.w800, letterSpacing: -.5)),
        const SizedBox(height: 4),
        Text(subtitle,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]);
}
