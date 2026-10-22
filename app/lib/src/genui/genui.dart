/// Aseman's generative UI, built on Flutter's genui (A2UI v0.9): the
/// catalog of components in the app's design language, the client
/// functions, and the widgets that render surfaces.
///
///   runtime/   values resolved from the data model, actions, functions,
///              message parsing and the surface manager
///   catalog/   basic, Aseman, extended and market components
///   widgets/   GenUiSurfaceView, GenUiView, and the compact (phone tile)
///              forms: GenUiCompactView, CompactSummaryView
library;

export 'catalog/catalog.dart';
export 'catalog/item.dart' show GenUiItem, asemanItem, P;
export 'catalog/style.dart' show genUiColor, genUiIcon, genUiTextStyle;
export 'runtime/dynamic_values.dart'
    show isBinding, isFunctionCall, Resolved, writeBinding;
export 'runtime/functions.dart' show allAsemanFunctions;
export 'runtime/host.dart';
export 'runtime/messages.dart';
export 'runtime/presentation.dart';
export 'runtime/surfaces.dart';
export 'widgets/app_frame.dart';
export 'widgets/compact_summary.dart';
export 'widgets/compact_surface.dart';
export 'widgets/surface_view.dart';
