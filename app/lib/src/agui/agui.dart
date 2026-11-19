/// Aseman AG-UI — in-chat generative surfaces (structured data + HITL).
///
/// Wire protocol payload is an `agui` / `surface` fenced JSON tree in the
/// message body. Widgets reuse the App UI kit (`features/tools/ui_kit`) so
/// there is one component vocabulary; HITL lives in [hitl.dart] only.
library;

export 'card_frame.dart';
export 'governance_cards.dart';
export 'hitl.dart';
export 'replies.dart';
export 'surface.dart';
export 'surface_view.dart';
