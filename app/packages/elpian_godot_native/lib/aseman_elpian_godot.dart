/// The embedded Godot 4 engine behind the `Scene3D` widget of Aseman's
/// Elpian engine.
///
/// This package carries only the native side — the Android/iOS platform view
/// and the op transport. The Dart API (`Scene3D`, `GodotSceneController`, the
/// op protocol) is in the app, under `lib/src/elpian/godot`. Without the
/// engine artifacts (see README.md), `Scene3D` shows its placeholder.
library aseman_elpian_godot;
