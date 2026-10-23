/// AG-UI Surface Spec in Elpian mini apps (lib/src/agui renders surfaces with
/// Aseman's catalog):
///
///   transport              the NDJSON agent stream
///   conversation           AG-UI surfaces + transport + transcript for one agent
///   elpian                 the AgUiSurface widget, registry and host APIs
///   agent_view             a full-screen agent app
library;

export '../../agui/agui.dart'
    show
        AgUiAction,
        AgUiProblemReport,
        AgUiSurfaces,
        AgUiSurfaceView,
        AgUiView,
        agUiClientVersion,
        parseLegacySurfaceMessage,
        asemanCatalog;
export 'agent_view.dart';
export 'conversation.dart';
export 'elpian.dart';
export 'transport.dart';
