import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Slide/fade transition used for desktop floating panels.
Widget desktopFloatingPanelTransition(
    BuildContext context, Animation<double> animation, Widget child) {
  final eased = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic);
  final fade = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic);
  final travel = math.min(240.0, MediaQuery.sizeOf(context).height * .28);
  return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, panel) {
        final motion = eased.value.clamp(0.0, 1.08);
        final opacity = fade.value.clamp(0.0, 1.0);
        final scale = .955 + .045 * motion.clamp(0.0, 1.0);
        return Opacity(
            opacity: opacity,
            child: Transform.translate(
                offset: Offset(0, travel * (1 - motion)),
                child: Transform.scale(scale: scale, child: panel)));
      });
}

/// Opens [child] as a responsive floating panel: a bottom sheet on compact
/// widths and a centered dialog on wider screens.
Future<void> showFloatingPanel(
  BuildContext context,
  Widget child, {
  double maxWidth = 1180,
  String barrierLabel = 'Close panel',
}) {
  if (MediaQuery.sizeOf(context).width < 820) {
    return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
        builder: (_) => FractionallySizedBox(heightFactor: .94, child: child));
  }
  return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: barrierLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (routeContext, __, ___) {
        final size = MediaQuery.sizeOf(routeContext);
        return Material(
            color: Theme.of(routeContext).colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(30),
            child: SizedBox(
                width: math.min(maxWidth, size.width - 48),
                height: math.min(780, size.height - 48),
                child: child));
      },
      transitionBuilder: (routeContext, animation, __, panel) => Align(
          alignment: Alignment.center,
          child:
              desktopFloatingPanelTransition(routeContext, animation, panel)));
}
