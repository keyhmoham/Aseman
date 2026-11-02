import 'package:flutter/material.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/theme/app_spacing.dart';
import 'app_brand.dart';
import 'sky_ui.dart';

class FeaturePage extends StatelessWidget {
  const FeaturePage(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.child,
      this.actions = const [],
      this.onBack,
      this.icon,
      this.sky = false});
  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  /// When provided, a back button is shown so pushed pages can return.
  final VoidCallback? onBack;

  /// Optional tonal icon well beside the heading.
  final IconData? icon;

  /// Optional atmosphere wash — off by default; opt in for rare hero pages.
  final bool sky;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.compact;
    final pad = AppSpacing.pagePadding(compact);
    final heading = _Heading(title, subtitle, icon: icon);
    final body = Column(children: [
      Padding(
        padding: EdgeInsets.fromLTRB(pad.left, pad.top, pad.right, AppSpacing.md),
        child: compact
            ? Row(children: [
                if (onBack != null)
                  IconButton(
                      onPressed: onBack,
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded))
                else
                  const AppBrand(compact: true),
                const Spacer(),
                ...actions,
              ])
            : Row(children: [
                if (onBack != null) ...[
                  IconButton(
                      onPressed: onBack,
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded)),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Expanded(child: heading),
                ...actions
              ]),
      ),
      if (compact)
        Padding(
            padding: EdgeInsets.fromLTRB(pad.left, 0, pad.right, AppSpacing.sm + 2),
            child: Align(alignment: Alignment.centerLeft, child: heading)),
      Expanded(child: child),
    ]);
    return Material(
      color: Colors.transparent,
      child: sky ? SkyBackdrop(child: body) : ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: body,
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, this.subtitle, {this.icon});
  final String title;
  final String subtitle;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return SkySectionHeader(
        icon: icon,
        title: title,
        subtitle: subtitle,
        dense: MediaQuery.sizeOf(context).width < Breakpoints.compact,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: -.55,
                height: 1.1,
              ) ??
              const TextStyle(
                  fontSize: 27, fontWeight: FontWeight.w900, letterSpacing: -.5)),
      const SizedBox(height: AppSpacing.xxs + 1),
      Text(subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              )),
    ]);
  }
}
