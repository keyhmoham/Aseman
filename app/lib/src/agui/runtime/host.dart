/// What a surface's host lends the catalog: how to embed a tool's own
/// frontend (`ToolFrontend`), the Elpian services raw `Elpian` nodes render
/// with, and the surface's theme overrides.
library;

import 'package:flutter/widgets.dart';

import '../../elpian/core/elpian_services.dart';

/// Builds the embedded frontend of [tool] at [height]; [props] are the
/// component's resolved props (`microtool` and `args`: the result to open it
/// on, when an agent showed one).
typedef AgUiToolFrontendBuilder = Widget Function(BuildContext context,
    String tool, double height, Map<String, dynamic> props);

class AgUiHost extends InheritedWidget {
  const AgUiHost({
    super.key,
    this.toolFrontend,
    this.elpianServices,
    required super.child,
  });

  final AgUiToolFrontendBuilder? toolFrontend;

  /// The mini app services `Elpian` escape-hatch nodes render in (its
  /// stylesheets, media); the shared services when null.
  final ElpianServices? elpianServices;

  static AgUiHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgUiHost>();

  @override
  bool updateShouldNotify(AgUiHost old) =>
      old.toolFrontend != toolFrontend ||
      old.elpianServices != elpianServices;
}
