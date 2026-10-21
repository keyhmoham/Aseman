import 'package:flutter/material.dart';

/// The motion of a page's panels when the user switches workspace, or moves
/// between a workspace and the feed: the page plays it in reverse to leave
/// and forward to arrive.
AnimationController workspaceMotionController(TickerProvider vsync,
        {double value = 1}) =>
    AnimationController(
        vsync: vsync,
        value: value,
        duration: const Duration(milliseconds: 420),
        reverseDuration: const Duration(milliseconds: 260));

/// Where each panel goes while the page is away. On wide screens the left
/// panel slides out to the left, the center shrinks away and the right panel
/// slides out to the right; on phones the single page sinks down.
abstract final class WorkspacePanelMotions {
  static const left = Offset(-.24, 0);
  static const right = Offset(.24, 0);
  static const centerScale = .94;
  static const mobileOffset = Offset(0, .06);
  static const mobileScale = .98;
}

/// One panel moved by a [workspaceMotionController]: it fades, slides from
/// [hiddenOffset] and grows from [scaleFrom] as the animation runs forward.
class WorkspacePanelMotion extends StatelessWidget {
  const WorkspacePanelMotion({
    super.key,
    required this.animation,
    required this.child,
    this.hiddenOffset = Offset.zero,
    this.scaleFrom = 1,
  });
  final Animation<double> animation;
  final Widget child;
  final Offset hiddenOffset;
  final double scaleFrom;
  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: hiddenOffset, end: Offset.zero)
            .animate(curved),
        child: ScaleTransition(
            scale: Tween<double>(begin: scaleFrom, end: 1).animate(curved),
            child: child),
      ),
    );
  }
}
