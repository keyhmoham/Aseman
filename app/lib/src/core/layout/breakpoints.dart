import 'package:flutter/widgets.dart';

/// Material 3 window size classes.
///
/// These are the single source of truth for adaptive layout decisions:
///
/// | class      | width        | columns | margin |
/// |------------|--------------|---------|--------|
/// | compact    | < 600        | 4       | 16     |
/// | medium     | 600 – 839    | 8       | 24     |
/// | expanded   | 840 – 1199   | 12      | 24     |
/// | large      | 1200 – 1599  | 12      | 24     |
/// | extraLarge | >= 1600      | 12      | 24     |
///
/// Feature code should ask for a class, not compare raw widths. Raw
/// comparisons are how the app ended up with fifteen different breakpoints.
enum AppWindowClass {
  compact(minWidth: 0, columns: 4, margin: 16),
  medium(minWidth: 600, columns: 8, margin: 24),
  expanded(minWidth: 840, columns: 12, margin: 24),
  large(minWidth: 1200, columns: 12, margin: 24),
  extraLarge(minWidth: 1600, columns: 12, margin: 24);

  const AppWindowClass({
    required this.minWidth,
    required this.columns,
    required this.margin,
  });

  /// The inclusive lower bound of the class, in logical pixels.
  final double minWidth;

  /// Layout grid columns recommended by Material 3.
  final int columns;

  /// Outer page margin recommended by Material 3.
  final double margin;

  bool get isCompact => this == AppWindowClass.compact;
  bool get isMedium => this == AppWindowClass.medium;

  /// Expanded and wider: enough room for a docked navigation rail.
  bool get hasNavigationRail => index >= AppWindowClass.expanded.index;

  /// Large and wider: a fixed pane beside one flexible pane.
  bool get hasSupportingPane => index >= AppWindowClass.large.index;

  /// Extra-large only. A third pane is not used below 1600dp.
  bool get hasThreePanes => this == AppWindowClass.extraLarge;

  bool atLeast(AppWindowClass other) => index >= other.index;

  static AppWindowClass fromWidth(double width) {
    if (width < AppWindowClass.medium.minWidth) return AppWindowClass.compact;
    if (width < AppWindowClass.expanded.minWidth) return AppWindowClass.medium;
    if (width < AppWindowClass.large.minWidth) return AppWindowClass.expanded;
    if (width < AppWindowClass.extraLarge.minWidth) return AppWindowClass.large;
    return AppWindowClass.extraLarge;
  }

  static AppWindowClass of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width);
}

/// Named Material 3 breakpoints, kept for call sites that still need a
/// single threshold. Prefer [AppWindowClass] in new code.
abstract final class Breakpoints {
  /// Compact window width: below this the app uses its phone shell.
  static const compact = 600.0;
  static const medium = 600.0;

  /// Expanded window width: the desktop shell and navigation rail start here.
  static const expanded = 840.0;
  static const large = 1200.0;
  static const extraLarge = 1600.0;

}

/// Material 3 height breakpoints. A compact height cannot hold two stacked
/// regions, so multi-pane layouts collapse to one pane.
enum AppHeightClass {
  compact(minHeight: 0),
  medium(minHeight: 480),
  expanded(minHeight: 900);

  const AppHeightClass({required this.minHeight});

  final double minHeight;

  bool get isCompact => this == AppHeightClass.compact;

  static AppHeightClass fromHeight(double height) {
    if (height < AppHeightClass.medium.minHeight) return AppHeightClass.compact;
    if (height < AppHeightClass.expanded.minHeight) return AppHeightClass.medium;
    return AppHeightClass.expanded;
  }
}

/// The window's size classes, published above any content-box [MediaQuery]
/// override so panes follow the window, not the area left after the rail.
class AppWindowScope extends InheritedWidget {
  const AppWindowScope({
    super.key,
    required this.widthClass,
    required this.heightClass,
    required super.child,
  });

  final AppWindowClass widthClass;
  final AppHeightClass heightClass;

  /// Large and wider, and tall enough for a second pane.
  bool get showSupportingPane =>
      widthClass.hasSupportingPane && !heightClass.isCompact;

  /// Extra-large and tall enough for a third pane.
  bool get showThreePanes => widthClass.hasThreePanes && !heightClass.isCompact;

  static AppWindowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppWindowScope>();

  /// Supporting pane from the scope, or from the raw media size when a
  /// screen is shown outside the desktop shell.
  static bool supportingPane(BuildContext context) {
    final scope = maybeOf(context);
    if (scope != null) return scope.showSupportingPane;
    final size = MediaQuery.sizeOf(context);
    return AppWindowClass.fromWidth(size.width).hasSupportingPane &&
        !AppHeightClass.fromHeight(size.height).isCompact;
  }

  /// Third pane from the scope, or from the raw media size outside the shell.
  static bool threePanes(BuildContext context) {
    final scope = maybeOf(context);
    if (scope != null) return scope.showThreePanes;
    final size = MediaQuery.sizeOf(context);
    return AppWindowClass.fromWidth(size.width).hasThreePanes &&
        !AppHeightClass.fromHeight(size.height).isCompact;
  }

  @override
  bool updateShouldNotify(AppWindowScope oldWidget) =>
      widthClass != oldWidget.widthClass ||
      heightClass != oldWidget.heightClass;
}
