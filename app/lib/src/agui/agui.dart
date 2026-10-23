/// Aseman's generative UI on the AG-UI protocol: Surface Spec catalog in the
/// app's design language, client functions, and widgets that render surfaces
/// in chat and on the desk.
///
///   protocol/  AG-UI events ↔ surface ops
///   runtime/   data model, actions, functions, surface manager
///   catalog/   basic, Aseman, extended, markets, chrome, forms, 2D/3D
///   widgets/   AgUiSurfaceView, AgUiView, compact phone tiles
library;

export 'catalog/catalog.dart';
export 'catalog/item.dart' show AgUiItem, asemanItem, P;
export 'catalog/style.dart' show agUiColor, agUiIcon, agUiTextStyle;
export 'protocol/events.dart';
export 'protocol/surface_ops.dart';
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
