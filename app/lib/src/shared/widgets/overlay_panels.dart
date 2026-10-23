import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_surfaces.dart';

/// Slide/fade transition used for every desktop modal: rises from below while
/// fading and gently scaling in.
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

/// Opens [builder]'s widget as a desktop modal with the shared bottom-to-top
/// fade-in. Prefer this over [showDialog] so every overlay matches.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String barrierLabel = 'Dismiss',
}) =>
    showGeneralDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        barrierLabel: barrierLabel,
        barrierColor: AppSurfaces.barrier,
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (routeContext, __, ___) => builder(routeContext),
        transitionBuilder: (routeContext, animation, __, panel) =>
            desktopFloatingPanelTransition(routeContext, animation, panel));

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

/// Opens [child] as a bottom sheet on compact widths and as an animated
/// theme-styled [Dialog] bounded by [maxWidth] x [maxHeight] elsewhere.
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
  return showAppDialog<T>(
      context: context,
      builder: (_) => Dialog(
          child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
              child: child)));
}

/// Opens a compact picker or action list: a bottom sheet on phones and, on
/// desktop, a floating panel pinned to the control that opened it.
///
/// Pass [anchor] (the button / row) or [anchorRect] / [anchorPoint] (e.g. a
/// long-press). Without an anchor the panel stays centered, for callers that
/// have no clear trigger geometry.
Future<T?> showAppPicker<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 420,
  double maxHeight = 480,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  double breakpoint = 600,
  BuildContext? anchor,
  Rect? anchorRect,
  Offset? anchorPoint,
}) {
  if (MediaQuery.sizeOf(context).width < breakpoint) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: true,
      builder: builder,
    );
  }

  final resolved = _resolvePickerAnchor(
    anchor: anchor,
    anchorRect: anchorRect,
    anchorPoint: anchorPoint,
  );
  if (resolved == null) {
    return showAppDialog<T>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          child: builder(ctx),
        ),
      ),
    );
  }

  final mq = MediaQuery.of(context);
  final pad = EdgeInsets.only(
    left: math.max(12, mq.padding.left),
    right: math.max(12, mq.padding.right),
    top: math.max(12, mq.padding.top),
    bottom: math.max(12, mq.padding.bottom),
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: AppSurfaces.barrier,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (routeContext, __, ___) => CustomSingleChildLayout(
      delegate: _AnchoredPickerLayout(
        anchor: resolved,
        padding: pad,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
      child: FloatingPanelSurface(
        elevation: 8,
        child: Material(
          type: MaterialType.transparency,
          child: builder(routeContext),
        ),
      ),
    ),
    transitionBuilder: (routeContext, animation, __, child) =>
        desktopFloatingPanelTransition(routeContext, animation, child),
  );
}

/// Global rect of the widget / point that opened a desktop picker.
Rect? _resolvePickerAnchor({
  BuildContext? anchor,
  Rect? anchorRect,
  Offset? anchorPoint,
}) {
  if (anchorRect != null) return anchorRect;
  if (anchorPoint != null) {
    return Rect.fromCenter(center: anchorPoint, width: 1, height: 1);
  }
  if (anchor == null || !anchor.mounted) return null;
  final box = anchor.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Places a picker under its anchor when there is room, otherwise above, and
/// keeps it on screen.
class _AnchoredPickerLayout extends SingleChildLayoutDelegate {
  _AnchoredPickerLayout({
    required this.anchor,
    required this.padding,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Rect anchor;
  final EdgeInsets padding;
  final double maxWidth;
  final double maxHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxW = math.min(
        maxWidth, math.max(0.0, constraints.maxWidth - padding.horizontal));
    final maxH = math.min(
        maxHeight, math.max(0.0, constraints.maxHeight - padding.vertical));
    return BoxConstraints(maxWidth: maxW, maxHeight: maxH);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = 6.0;
    final spaceBelow = size.height - padding.bottom - anchor.bottom - gap;
    final spaceAbove = anchor.top - padding.top - gap;
    final double top;
    if (childSize.height <= spaceBelow || spaceBelow >= spaceAbove) {
      top = anchor.bottom + gap;
    } else {
      top = anchor.top - childSize.height - gap;
    }
    // Prefer the anchor's leading edge; clamp so the panel stays on screen.
    final maxLeft = size.width - padding.right - childSize.width;
    final left =
        anchor.left.clamp(padding.left, math.max(padding.left, maxLeft)).toDouble();
    final maxTop = size.height - padding.bottom - childSize.height;
    final clampedTop =
        top.clamp(padding.top, math.max(padding.top, maxTop)).toDouble();
    return Offset(left, clampedTop);
  }

  @override
  bool shouldRelayout(covariant _AnchoredPickerLayout old) =>
      old.anchor != anchor ||
      old.padding != padding ||
      old.maxWidth != maxWidth ||
      old.maxHeight != maxHeight;
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
    showAppDialog<T>(
        context: context,
        barrierLabel: barrierLabel,
        builder: pageBuilder);

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
