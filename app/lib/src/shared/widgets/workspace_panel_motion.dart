import 'package:flutter/material.dart';

/// Kept so workspace switches can still sequence leave and arrive. The
/// duration is zero: panels appear and disappear in place.
AnimationController workspaceMotionController(TickerProvider vsync,
        {double value = 1}) =>
    AnimationController(
        vsync: vsync,
        value: value,
        duration: Duration.zero,
        reverseDuration: Duration.zero);

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

/// A panel on a [workspaceMotionController]. It stays put; [hiddenOffset] and
/// [scaleFrom] are unused.
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
  Widget build(BuildContext context) => child;
}
