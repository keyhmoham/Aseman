import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'breakpoints.dart';

/// Shared desktop layout metrics.
///
/// Material 3 guidance: 4/8 spacing grid, 16dp compact margins, 24dp
/// medium/expanded margins, 48dp minimum targets, 360dp list/supporting
/// panes, and a 1200dp content cap so reading measure stays comfortable on
/// large monitors.
abstract final class AppLayout {
  /// Collapsed navigation rail (M3 Expressive: 96dp, labels under icons).
  static const double navigationRailWidth = 96;

  /// Expanded navigation rail. Expressive range is 220–360; 280 is the default.
  static const double extendedNavigationRailWidth = 280;

  /// A list / library pane.
  static const double listPaneWidth = 360;

  /// A supporting pane. Side sheets cap at 400dp.
  static const double supportingPaneWidth = 400;

  /// Minimum width left for the flexible pane beside fixed panes.
  static const double flexiblePaneMin = 360;

  /// Maximum width for body content on large screens.
  static const double maxContentWidth = 1200;

  /// Maximum width for a single reading column.
  static const double readingWidth = 760;

  /// Modal dialog width cap.
  static const double dialogMaxWidth = 560;

  /// Side sheet / supporting sheet width.
  static const double sideSheetWidth = 360;

  /// Material minimum interactive target.
  static const double minTargetSize = 48;

  /// M3 motion durations.
  static const Duration motionFast = Duration(milliseconds: 150);
  static const Duration motionMedium = Duration(milliseconds: 300);
  static const Duration motionSlow = Duration(milliseconds: 450);

  static double pageMargin(AppWindowClass windowClass) => windowClass.margin;

  static double gutter(AppWindowClass windowClass) =>
      windowClass.isCompact ? 16 : 24;

  static EdgeInsets pageInsets(AppWindowClass windowClass) =>
      EdgeInsets.symmetric(horizontal: pageMargin(windowClass));

  /// Widths for a fixed-and-flexible row inside [innerWidth].
  ///
  /// Preferred widths are kept when the flexible pane still has
  /// [flexiblePaneMin]. Otherwise the fixed panes shrink together, down to
  /// 220dp, so an expanded window can still hold two panes.
  static ({double leading, double trailing}) paneWidths({
    required double innerWidth,
    required bool leading,
    required bool trailing,
  }) {
    if (!leading && !trailing) return (leading: 0, trailing: 0);
    final fixedCount = (leading ? 1 : 0) + (trailing ? 1 : 0);
    final gutters = gutterWidth * fixedCount;
    final leadPref = leading ? listPaneWidth : 0.0;
    final trailPref = trailing ? supportingPaneWidth : 0.0;
    final need = leadPref + trailPref + gutters + flexiblePaneMin;
    if (innerWidth >= need) return (leading: leadPref, trailing: trailPref);
    final share = ((innerWidth - gutters - flexiblePaneMin) / fixedCount).clamp(
      220.0,
      listPaneWidth,
    );
    return (
      leading: leading ? share : 0,
      trailing: trailing ? math.min(share, supportingPaneWidth) : 0,
    );
  }

  static const double gutterWidth = 24;

  /// Height of the docked conversation or feed under the desk on large windows.
  static const double stageBandHeight = 300;

  /// Width of the room-desk pane on the desktop workspace.
  ///
  /// It sits to the right of the chat. [libraryWidth] is the leading library
  /// already taken from [innerWidth]. The result stays narrower than the chat
  /// pane that remains, and near a phone width so the widget grid matches
  /// the compact board.
  static double roomDeskPaneWidth({
    required double innerWidth,
    required double libraryWidth,
  }) {
    const preferred = 360.0;
    const least = 220.0;
    final dividers = libraryWidth > 0 ? 2.0 : 1.0;
    final rest = math.max(0.0, innerWidth - libraryWidth - dividers);
    // The chat keeps the larger share of what remains.
    final narrowerThanChat = rest / 2 - 24;
    if (narrowerThanChat <= least) {
      return narrowerThanChat.clamp(160.0, least).toDouble();
    }
    return math.min(preferred, narrowerThanChat);
  }

  /// A centered, width-capped body. [fillHeight] is true for page bodies
  /// that should own the full height (lists, chats, settings).
  static Widget content({
    required BuildContext context,
    required Widget child,
    double maxWidth = maxContentWidth,
    EdgeInsetsGeometry? padding,
    bool fillHeight = true,
    Alignment alignment = Alignment.topCenter,
  }) {
    final windowClass = AppWindowClass.of(context);
    final insets =
        padding ??
        EdgeInsets.symmetric(horizontal: pageMargin(windowClass), vertical: 0);
    return LayoutBuilder(
      builder: (context, box) {
        final horizontal = insets.horizontal;
        final vertical = insets.vertical;
        final availableWidth = math.max(0.0, box.maxWidth - horizontal);
        final width = math.min(maxWidth, availableWidth);
        final height = fillHeight && box.hasBoundedHeight
            ? math.max(0.0, box.maxHeight - vertical)
            : null;
        return Padding(
          padding: insets,
          child: Align(
            alignment: alignment,
            child: SizedBox(width: width, height: height, child: child),
          ),
        );
      },
    );
  }
}

/// Gives descendants a [MediaQuery] whose size is the available content box
/// rather than the whole window.
///
/// A desktop rail removes 80–256 logical pixels from the content area. Without
/// this override every feature's `MediaQuery.sizeOf(context).width` would keep
/// reporting the full window and make the wrong pane decision.
class AppContentMedia extends StatelessWidget {
  const AppContentMedia({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (!box.hasBoundedWidth || !box.hasBoundedHeight) return child;
      final media = MediaQuery.of(context);
      final size = Size(box.maxWidth, box.maxHeight);
      if (media.size == size) return child;
      return MediaQuery(
        data: media.copyWith(size: size),
        child: child,
      );
    },
  );
}

/// A width-capped page body with the app's standard margins.
class AppContent extends StatelessWidget {
  const AppContent({
    super.key,
    required this.child,
    this.maxWidth = AppLayout.maxContentWidth,
    this.padding,
    this.fillHeight = true,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final bool fillHeight;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => AppLayout.content(
    context: context,
    maxWidth: maxWidth,
    padding: padding,
    fillHeight: fillHeight,
    alignment: alignment,
    child: child,
  );
}

/// A hairline between two panes that share an edge.
class PaneDivider extends StatelessWidget {
  const PaneDivider({super.key, this.axis = Axis.vertical});

  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: .5);
    if (axis == Axis.horizontal) {
      return Divider(height: 1, thickness: 1, color: color);
    }
    return VerticalDivider(width: 1, thickness: 1, color: color);
  }
}

/// A pane that fills its slot and meets its neighbors on a shared edge.
class AppPane extends StatelessWidget {
  const AppPane({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding = EdgeInsets.zero,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: height,
      child: Material(
        color: scheme.surfaceContainerLow,
        clipBehavior: clipBehavior,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Standard destination metadata for the desktop navigation rail.
@immutable
class AppDestination {
  const AppDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
