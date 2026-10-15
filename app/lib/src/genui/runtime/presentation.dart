/// How a frontend is being shown, for every kind of frontend (generative
/// A2UI, static Elpian programs, tools' apps): in full (a desk card window),
/// as a compact widget (a tile on the phone board: a summary of the data),
/// or in a sheet (the full frontend opened from a compact widget on a
/// phone). Frontends read it with [FrontendPresentation.of] and report what
/// the shell may use: their compact summary, a preferred tile look, a wish
/// to open in full.
library;

import 'package:flutter/widgets.dart';

enum FrontendDisplay {
  /// A card window on the desk (desktop): the whole frontend.
  full,

  /// A tile on the phone board: minimal information about the data.
  compact,

  /// The whole frontend in a bottom sheet, phone-wide.
  sheet,
}

/// A frontend's preferred tile on the phone board.
class CompactHint {
  const CompactHint({this.shape = '', this.size = ''});

  factory CompactHint.fromJson(Object? json) {
    final m = json is Map ? json : const <String, Object?>{};
    return CompactHint(
      shape: '${m['shape'] ?? m['compactShape'] ?? ''}',
      size: '${m['size'] ?? m['compactSize'] ?? ''}',
    );
  }

  final String shape;
  final String size;

  bool get isEmpty => shape.isEmpty && size.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is CompactHint && other.shape == shape && other.size == size;

  @override
  int get hashCode => Object.hash(shape, size);
}

class FrontendPresentation extends InheritedWidget {
  const FrontendPresentation({
    super.key,
    required this.display,
    this.shape = 'card',
    this.size = 'medium',
    this.onHint,
    this.onExpand,
    required super.child,
  });

  final FrontendDisplay display;

  /// The tile's shape and size (compact display).
  final String shape;
  final String size;

  /// A frontend's preferred tile look.
  final ValueChanged<CompactHint>? onHint;

  /// Opens the frontend in full (from a compact tile).
  final VoidCallback? onExpand;

  static FrontendPresentation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FrontendPresentation>();

  /// How the frontend at [context] is shown ([FrontendDisplay.full] when
  /// nothing says otherwise).
  static FrontendDisplay displayOf(BuildContext context) =>
      maybeOf(context)?.display ?? FrontendDisplay.full;

  static bool isCompact(BuildContext context) =>
      displayOf(context) == FrontendDisplay.compact;

  @override
  bool updateShouldNotify(FrontendPresentation old) =>
      old.display != display || old.shape != shape || old.size != size;
}
