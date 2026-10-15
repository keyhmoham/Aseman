/// Tradera's generative UI, built on Flutter's genui (A2UI v0.9): the
/// catalog of components in the app's design language, the client
/// functions, and the widgets that render surfaces.
///
///   runtime/   values resolved from the data model, actions, functions,
///              message parsing and the surface manager
///   catalog/   basic, Tradera, extended and market components
///   widgets/   GenUiSurfaceView, GenUiView
library;

export 'catalog/catalog.dart';
export 'catalog/item.dart' show GenUiItem, traderaItem, P;
export 'catalog/style.dart' show genUiColor, genUiIcon, genUiTextStyle;
export 'runtime/dynamic_values.dart'
    show isBinding, isFunctionCall, Resolved, writeBinding;
export 'runtime/functions.dart' show allTraderaFunctions;
export 'runtime/host.dart';
export 'runtime/messages.dart';
export 'runtime/surfaces.dart';
export 'widgets/surface_view.dart';
