import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_surfaces.dart';

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

/// Opens [child] as a modal bottom sheet styled by the app theme. When
/// [heightFactor] is set the sheet is scroll-controlled and takes that share
/// of the screen height.
Future<T?> showAppSheet<T>(
  BuildContext context,
  Widget child, {
  double? heightFactor,
  bool isScrollControlled = false,
}) =>
    showModalBottomSheet<T>(
        context: context,
        isScrollControlled: isScrollControlled || heightFactor != null,
        useSafeArea: true,
        builder: (_) => heightFactor == null
            ? child
            : FractionallySizedBox(heightFactor: heightFactor, child: child));

/// Opens [child] as a bottom sheet on compact widths and as a theme-styled
/// [Dialog] bounded by [maxWidth] x [maxHeight] elsewhere.
Future<T?> showAdaptivePanel<T>(
  BuildContext context,
  Widget child, {
  double maxWidth = 780,
  double maxHeight = 820,
  double breakpoint = 600,
  double heightFactor = .94,
}) {
  if (MediaQuery.sizeOf(context).width < breakpoint) {
    return showAppSheet<T>(context, child, heightFactor: heightFactor);
  }
  return showDialog<T>(
      context: context,
      builder: (_) => Dialog(
          child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
              child: child)));
}

/// The surface every floating panel sits on: the theme's overlay colour and
/// corner radius, matching dialogs and bottom sheets.
class FloatingPanelSurface extends StatelessWidget {
  const FloatingPanelSurface({super.key, required this.child, this.elevation});
  final Widget child;
  final double? elevation;

  @override
  Widget build(BuildContext context) => Material(
      color: AppSurfaces.overlay(Theme.of(context).colorScheme),
      surfaceTintColor: Colors.transparent,
      elevation: elevation ?? 0,
      shadowColor: Colors.black45,
      clipBehavior: Clip.antiAlias,
      shape: AppSurfaces.overlayShape,
      child: child);
}

/// Shows [pageBuilder]'s widget as an animated floating panel over the
/// app's shared scrim.
Future<T?> showFloatingDialog<T>(
  BuildContext context, {
  required WidgetBuilder pageBuilder,
  String barrierLabel = 'Close panel',
}) =>
    showGeneralDialog<T>(
        context: context,
        barrierDismissible: true,
        barrierLabel: barrierLabel,
        barrierColor: AppSurfaces.barrier,
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (routeContext, __, ___) => pageBuilder(routeContext),
        transitionBuilder: (routeContext, animation, __, panel) =>
            desktopFloatingPanelTransition(routeContext, animation, panel));

/// Opens [child] as a responsive floating panel: a bottom sheet on compact
/// widths and a centered dialog on wider screens.
Future<void> showFloatingPanel(
  BuildContext context,
  Widget child, {
  double maxWidth = 1180,
  double maxHeight = 780,
  String barrierLabel = 'Close panel',
}) {
  if (MediaQuery.sizeOf(context).width < 820) {
    return showAppSheet<void>(context, child, heightFactor: .94);
  }
  return showFloatingDialog<void>(context, barrierLabel: barrierLabel,
      pageBuilder: (routeContext) {
    final size = MediaQuery.sizeOf(routeContext);
    return Align(
        alignment: Alignment.center,
        child: FloatingPanelSurface(
            child: SizedBox(
                width: math.min(maxWidth, size.width - 48),
                height: math.min(maxHeight, size.height - 48),
                child: child)));
  });
}
