/// Corner radii shared by every surface in the app.
abstract final class AppShape {
  /// Cards, dialogs, bottom sheets and floating panels.
  static const card = 28.0;
  static const inner = 20.0;
  static const control = 16.0;

  /// Material 3 Expressive FAB container corners (size-adaptive).
  /// Leave [ThemeData.floatingActionButtonTheme.shape] null so Flutter picks
  /// these per size; use the matching constant on hand-rolled FAB circles.
  static const fab = 16.0;
  static const fabSmall = 12.0;
  static const fabLarge = 28.0;
}
