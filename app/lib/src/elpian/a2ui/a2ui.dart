/// A2UI v0.9 in Elpian mini apps, on Flutter's genui (lib/src/genui renders
/// the surfaces with Tradera's catalog):
///
///   transport              the NDJSON agent stream
///   conversation           genui surfaces + transport + transcript for one agent
///   elpian                 the A2UISurface widget, registry and host APIs
///   agent_view             a full-screen agent app
library;

export '../../genui/genui.dart'
    show
        GenUiAction,
        GenUiProblemReport,
        GenUiSurfaces,
        GenUiSurfaceView,
        GenUiView,
        a2uiClientVersion,
        parseA2uiMessage,
        traderaCatalog;
export 'agent_view.dart';
export 'conversation.dart';
export 'elpian.dart';
export 'transport.dart';
